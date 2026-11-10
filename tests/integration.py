"""Exercise SCU through its command line in isolated libraries."""
import concurrent.futures
from contextlib import closing, contextmanager
from datetime import datetime
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

SCU = Path(sys.argv.pop(1)).resolve()


class ScuIntegration(unittest.TestCase):
    def setUp(self):
        directory = tempfile.TemporaryDirectory()
        self.addCleanup(directory.cleanup)
        self.root = Path(directory.name)
        self.library = self.root / "library.sqlite"
        self.run_scu(self.library, "init")

    def run_scu(self, *arguments, error=None, executable=SCU):
        result = subprocess.run(
            [executable, *arguments], cwd=self.root, capture_output=True, text=True, timeout=20
        )
        if error is None:
            self.assertEqual(result.returncode, 0, result.stderr)
        else:
            self.assertNotEqual(result.returncode, 0, result.stdout)
            self.assertIn(error, result.stderr)
        return result.stdout.strip()

    def store(self, name, source, *options):
        path = self.root / "input"
        path.write_bytes(source)
        self.run_scu("store_deck", name, path, *options)

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

    def test_executor_accepts_and_audits_a_command_without_the_cli(self):
        database = self.root / "frontend.sqlite"
        subprocess.run([SCU.with_name("executor_probe"), database], cwd=self.root,
                       check=True, capture_output=True, timeout=5)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(database)]
        creation = events[2]
        self.assertEqual(creation["command"], "create_deck")
        self.assertEqual(creation["parameters"], {"deck_name": "example.pas", "from_file": ""})
        self.assertEqual(creation["provided_arguments"], ["deck_name"])
        self.assertEqual(creation["options"], {"comment-prefix": "#"})
        self.assertIn("records=6 interrupted=0", self.run_scu(database, "verify_audit"))

    def test_expand_commands_run_the_configured_build_after_writing_outputs(self):
        self.store("main.pas", b"main\n")
        self.store("shared.inc", b"shared\n")
        (self.root / "batch outputs").mkdir()
        (self.root / "build-script").write_text(
            'if [ -d "$1" ]; then\n'
            '  test -f "$1/main.pas" && test -f "$1/shared.inc" || exit 8\n'
            'else\n'
            '  test -f "$1" || exit 8\n'
            'fi\n'
            'printf "%s\\n" "$1" >> build-targets\n'
            f'{shlex.quote(str(SCU))} verify_audit >/dev/null\n'
        )
        command = 'sh build-script "$1"'
        self.run_scu("modify_library", f"build_command={command}")
        self.assertEqual(json.loads(self.run_scu("show_library"))["build_command"], command)
        self.run_scu("expand_deck", "main.pas", "expanded file")
        self.run_scu("expand_deck", "main.pas", "export only", "build=n")
        self.run_scu("expand_modified_decks", "1.0", "batch outputs")
        self.run_scu("expand_modified_decks", "1.0", "batch outputs", "build=no")
        targets = (self.root / "build-targets").read_text().splitlines()
        self.assertEqual(targets, [str(self.root / "expanded file"), str(self.root / "batch outputs")])
        self.assertEqual((self.root / "export only").read_bytes(), b"main\n")

        self.run_scu("modify_library", "build_command=exit 7")
        self.run_scu("expand_deck", "main.pas", "failed build", error="Build command failed with exit status 7")
        self.assertEqual((self.root / "failed build").read_bytes(), b"main\n")
        records = self.audit_lines()
        events = [json.loads(line.split(b" ", 1)[1]) for line in records]
        builds = [event for event in events if event["phase"] == "build"]
        self.assertEqual([event["success"] for event in builds], [True, True, False])
        self.assertEqual([event["build_command"] for event in builds], [command, command, "exit 7"])
        self.assertEqual([event["output_path"] for event in builds], targets + [str(self.root / "failed build")])
        self.assertEqual(builds[-1]["expansion"], records[-2].split(b" ", 1)[0].decode())
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))
        self.run_scu("modify_library", "--build_command", "")
        self.assertEqual(json.loads(self.run_scu("show_library"))["build_command"], "")

    def test_review_safe_output_defaults_and_redirected_commands(self):
        self.store("shared.inc", b"shared\n")
        self.store("main.pas", b"main\n")
        working = self.root / "main.pas"
        working.write_bytes(b"unsaved work\n")
        self.run_scu("extd", "shared.inc", "output_file=", error="Expected a file path")
        self.run_scu("expd", "shared.inc", "output_file=", "build=no", error="Expected a file path")
        self.run_scu("extd", "shared.inc", "--revision=+01")
        self.assertEqual((self.root / "shared.inc").read_bytes(), b"shared\n")
        self.assertEqual(working.read_bytes(), b"unsaved work\n")
        self.run_scu("lock_verison", error='Unknown command "lock_verison"')
        self.run_scu("extrct_deck", "main.pas", "x.pas", error='Unknown command "extrct_deck"')

        self.run_scu("conl", "bc=cat > build-input")
        result = subprocess.run(
            [SCU], cwd=self.root, input="expd shared.inc batch-out\ncred\ncred after-build\n",
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Missing required argument deck_name", result.stderr)
        self.assertEqual((self.root / "build-input").read_bytes(), b"")
        self.assertIn("after-build\t", self.run_scu("ddl"))
        self.run_scu("conl", "bc=")
        self.assertEqual(json.loads(self.run_scu("show_library"))["build_command"], "")

    def test_empty_named_output_does_not_consume_the_following_deck(self):
        self.store("main.pas", b"stored main\n")
        self.store("shared.inc", b"stored shared\n")
        working = self.root / "main.pas"
        working.write_bytes(b"unsaved work\n")
        for command in ("extract_deck", "expand_deck"):
            with self.subTest(command=command):
                result = subprocess.run(
                    ["sh", "-c", 'OUT=""; "$1" "$2" output_file=$OUT main.pas', "sh", SCU, command],
                    cwd=self.root, capture_output=True, text=True, timeout=5,
                )
                self.assertEqual(result.returncode, 1, result.stdout)
                self.assertIn("Expected a file path", result.stderr)
                self.assertEqual(working.read_bytes(), b"unsaved work\n")
        result = subprocess.run([SCU], cwd=self.root, input='extd o="" main.pas\n',
                                capture_output=True, text=True, timeout=5)
        self.assertEqual(result.returncode, 1, result.stdout)
        self.assertIn("Expected a file path", result.stderr)
        self.assertEqual(working.read_bytes(), b"unsaved work\n")

    def test_review_editor_uses_path_and_removes_backup_files(self):
        self.store("main", b"old")
        programs = self.root / "programs"
        programs.mkdir()
        (self.root / "vi").write_text("#!/bin/sh\ntouch wrong-editor\n")
        (self.root / "vi").chmod(0o700)
        editor = programs / "vi"
        editor.write_text('#!/bin/sh\nprintf "%s" "$1" > editor-path\n'
                          'printf backup > "$1~"\nprintf edited > "$1"\n')
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
        self.assertEqual(self.run_scu("store_deck", "main", "input"), "No changes to main")
        self.assertEqual(len(self.read_library()["revisions"]), 1)
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.02", error="must be greater")
        self.assertEqual(self.run_scu("start_version"), "Started version 1.11")
        output = self.root / "mode-output"
        result = subprocess.run([SCU, "extd", "main", output], cwd=self.root, umask=0o027,
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(output.stat().st_mode & 0o777, 0o640)
        output.chmod(0o751)
        self.run_scu("extd", "main", output)
        self.assertEqual(output.stat().st_mode & 0o777, 0o751)

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
        self.run_scu("store_deck", "main.pas", "input", error="has reached the revision limit")
        self.assertEqual(self.read_library(), unchanged)
        self.run_scu("lock_version")
        self.assertEqual(self.run_scu("start_version"), "Started version 1.03")
        self.assertTrue(self.run_scu("dd", "main.pas").splitlines()[0].endswith("1.0-0.999"))
        self.store("main.pas", b"new release\n")
        self.assertTrue(self.run_scu("dd", "main.pas").splitlines()[0].endswith("1.03-0.000"))
        expected_patch = "-old release\n+new release"
        self.assertIn(expected_patch, self.run_scu("diff_deck"))
        self.assertIn(expected_patch, self.run_scu("diff_deck", "main.pas", "1.0-0.999", "1.03-0.000"))
        self.run_scu("extract_deck", "main.pas", "old", "version=1.0-0.999")
        self.assertEqual((self.root / "old").read_bytes(), b"old release\n")
        self.run_scu("configure_library", "ri=0.002")
        self.store("main.pas", b"next edit\n")
        history = self.run_scu("dd", "main.pas").splitlines()
        self.assertEqual([line.split("\t")[-1] for line in history[:3]],
                         ["1.03-0.002", "1.03-0.000", "1.0-0.999"])
        self.assertEqual(self.run_scu("ddl"), "main.pas\t1.03-0.002\nother\t1.0-0.000")

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
        self.assertEqual([line.split("\t")[-1] for line in self.run_scu("dd", "main").splitlines()],
                         ["1.0-0.001", "1.0-0.000"])
        self.assertEqual(self.read_library(), original)
        self.store("main", b"new\n")
        self.assertEqual(self.read_library()["revisions"][-1]["deck_revision"], "0.002")

    def test_last_modified_deck_defaults_follow_the_working_library(self):
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "")
        self.run_scu("display_deck", error="No deck has been modified")
        self.run_scu("extd", error="No deck has been modified")
        self.run_scu("expd", error="No deck has been modified")
        self.run_scu("edid", error="No deck has been modified")
        self.store("main.pas", b"old\n")
        self.store("other.pas", b"unrelated\n")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "other.pas")
        self.store("MAIN.PAS", b"new\n//SCU$VERSION\n")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "main.pas")

        self.assertEqual(self.run_scu("display_deck"), self.run_scu("display_deck", "main.pas"))
        self.assertTrue(self.run_scu("dd", "dn=SCU$LAST_MODIFIED_DECK").startswith("3\t1.1\t"))
        self.assertIn("--- main.pas@1.0-0.000\n+++ main.pas@1.1-0.000", self.run_scu("diff_deck"))
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"]["deck_name"], "scu$last_modified_deck")
        self.assertEqual(outcome["resolved_deck"], "main.pas")

        self.run_scu("extd", "output_file=last-source")
        self.assertEqual((self.root / "last-source").read_bytes(), b"new\n//SCU$VERSION\n")
        self.run_scu("extd")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"new\n//SCU$VERSION\n")
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"], {"deck_name": "scu$last_modified_deck",
                                              "output_file": "scu$deck_name"})
        self.assertEqual(outcome["resolved_deck"], "main.pas")
        self.run_scu("expd", "output_file=last-expanded")
        self.assertEqual((self.root / "last-expanded").read_bytes(), b"new\n1.1\n")
        self.run_scu("expd")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"new\n1.1\n")
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"], {"deck_name": "scu$last_modified_deck",
                                              "output_file": "scu$deck_name"})
        self.assertEqual(outcome["resolved_deck"], "main.pas")
        self.run_scu("expd", "other.pas")
        self.assertEqual((self.root / "other.pas").read_bytes(), b"unrelated\n")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"new\n1.1\n")
        self.run_scu("configure_library", "editor=[\"true\"]")
        self.assertEqual(self.run_scu("edid"), "No changes to main.pas")
        begin, outcome = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()[-2:]]
        self.assertEqual(begin["parameters"]["deck_name"], "scu$last_modified_deck")
        self.assertEqual(outcome["resolved_deck"], "main.pas")

        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"create_deck pending.pas\n")
            self.assertIn(b"pending.pas version 1.1 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"dd\n")
            self.assertIn(b"4\t1.1\t", read_until(b"scu> "))
            os.write(terminal, b"dd dn=scu$last\t\n")
            self.assertIn(b"4\t1.1\t", read_until(b"scu> "))
            os.write(terminal, b"edid\n")
            self.assertIn(b"No changes to pending.pas", read_until(b"scu> "))
            os.write(terminal, b"extd\n")
            response = read_until(b"scu> ")
            self.assertNotIn(b"deck_name= ", response)
            self.assertNotIn(b"output_file= ", response)
            self.assertEqual((self.root / "pending.pas").read_bytes(), b"")
            (self.root / "pending.pas").unlink()
            os.write(terminal, b"expd\n")
            response = read_until(b"scu> ")
            self.assertNotIn(b"deck_name= ", response)
            self.assertNotIn(b"output_file= ", response)
            self.assertEqual((self.root / "pending.pas").read_bytes(), b"")
            os.write(terminal, b"quit save_library=no\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "main.pas")

    def test_last_modified_deck_is_inferred_for_older_libraries(self):
        self.store("legacy", b"source\n")
        document = self.read_library()
        del document["header"]["last_modified_deck"]
        self.write_library(document)
        original = self.read_library()
        self.assertEqual(json.loads(self.run_scu("show_library"))["last_modified_deck"], "legacy")
        self.assertTrue(self.run_scu("dd").startswith("1\t1.0\t"))
        self.assertEqual(self.read_library(), original)
        self.run_scu("create_deck", "new")
        self.assertEqual(self.read_library()["header"]["last_modified_deck"], "new")

    def test_create_deck_creates_empty_or_imported_first_revisions(self):
        empty_digest = hashlib.sha1(b"").hexdigest()
        self.assertEqual(self.run_scu("create_deck", "Empty.pas"),
                         "empty.pas version 1.0 revision 0.000, deck version 1.0-0.000")
        source = b"// initial source\r\n\x00\xff"
        (self.root / "initial source").write_bytes(source)
        digest = hashlib.sha1(source).hexdigest()
        self.assertEqual(self.run_scu("cred", "dn=Imported.pas", "ff=initial source"),
                         "imported.pas version 1.0 revision 0.000, deck version 1.0-0.000")
        self.assertEqual([entry["sha1"] for entry in self.read_library()["revisions"]],
                         [empty_digest, digest])
        self.run_scu("extract_deck", "empty.pas", "empty-output")
        self.run_scu("extract_deck", "imported.pas", "imported-output")
        self.assertEqual((self.root / "empty-output").read_bytes(), b"")
        self.assertEqual((self.root / "imported-output").read_bytes(), source)

        unchanged = self.read_library()
        self.run_scu("create_deck", "IMPORTED.pas", "initial source", error="already exists")
        self.run_scu("create_deck", "unreadable", "from_file=missing", error="Could not open missing")
        self.assertEqual(self.read_library(), unchanged)
        self.run_scu("lock_version")
        self.run_scu("create_deck", "new.pas", error="is locked")
        self.run_scu("start_version", "1.1")
        self.run_scu("create_deck", "empty.pas", error="already exists")

        result = subprocess.run([SCU], cwd=self.root, input="create_deck new.pas\nquit\n",
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "")
        self.assertIn("new.pas version 1.1 revision 0.000", result.stdout)
        self.assertEqual(len(self.read_library()["revisions"]), 3)

        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        creates = [event["parameters"] for event in events if event.get("command") == "create_deck"]
        self.assertEqual(creates[:2], [{"deck_name": "Empty.pas", "from_file": ""},
                                      {"deck_name": "Imported.pas", "from_file": "initial source"}])
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

    def test_locked_version_expands_stored_timestamps_and_old_dependencies(self):
        main = b"'SCU$VERSION SCU$DATE SCU$TIME'\r\n//SCU_COPY Common.inc\r\n"
        common = b"//$SCU_DATE $SCU_TIME"
        self.store("Main.pas", main)
        time.sleep(1.05)
        self.store("common.inc", common)
        stamps = [entry["modified_utc"] for entry in self.read_library()["revisions"]]
        self.assertNotEqual(stamps[0][:19], stamps[1][:19])

        self.run_scu("extract_deck", "MAIN.PAS", "raw")
        self.assertEqual((self.root / "raw").read_bytes(), main)
        self.run_scu("start_version", "1.1", error="Lock version")
        self.run_scu("lock_version")
        self.run_scu("store_deck", "main.pas", "input", error="is locked")
        self.run_scu("start_version", "1.1")
        self.store("Common.inc", b"new text")

        self.run_scu("expand_deck", "main.pas", "old", "--version", "1.0")
        self.run_scu("expand_deck", "main.pas", "old-by-revision", "--revision", "2")
        expected = (
            f"'1.0 {stamps[0][:10]} {stamps[0][11:19]}'\r\n"
            f"{stamps[1][:10]} {stamps[1][11:19]}\r\n"
        ).encode()
        self.assertEqual((self.root / "old").read_bytes(), expected)
        self.assertEqual((self.root / "old-by-revision").read_bytes(), expected)
        self.run_scu("expand_deck", "main.pas", "current")
        self.assertIn(b"'1.1 ", (self.root / "current").read_bytes())
        self.assertIn(b"new text\r\n", (self.root / "current").read_bytes())

        self.store("Common.inc", b"latest")
        for mode in ("extract", "expand"):
            output = self.root / mode
            output.mkdir()
            self.run_scu(f"{mode}_modified_decks", "1.1", output)
            expected = {"common.inc", "main.pas"} if mode == "expand" else {"common.inc"}
            self.assertEqual({item.name for item in output.iterdir()}, expected)
            self.assertEqual((output / "common.inc").read_bytes(), b"latest")

    def test_expansion_macros_distinguish_deck_library_and_expansion_metadata(self):
        names = (
            "DECK_VERSION", "LIBRARY_VERSION", "LAST_MODIFIED_DATE", "LAST_MODIFIED_TIME",
            "LAST_MODIFIED_DATE_TIME", "EXPANSION_DATE", "EXPANSION_TIME", "EXPANSION_DATE_TIME",
        )
        macros = "//" + " ".join("SCU$" + name for name in names) + "\n"
        self.store("common", macros.encode())
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        source = (macros + "//SCU_COPY common\n//scu$deck_version\n").encode()
        self.store("main", source)
        self.store("other", macros.encode())
        common, main, _ = self.read_library()["revisions"]

        def check_expanded(path, before, after):
            lines = path.read_text().splitlines()
            clocks = []
            for line, entry, version in zip(lines, (main, common), ("1.1-0.000", "1.0-0.000")):
                fields = line.split()
                modified = entry["modified_utc"]
                self.assertEqual(fields[:5], [version, "1.1", modified[:10], modified[11:19], modified])
                expanded = fields[7]
                self.assertRegex(expanded, r"^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}\.\d{3}Z$")
                self.assertEqual(fields[5:7], [expanded[:10], expanded[11:19]])
                epoch = datetime.fromisoformat(expanded.replace("Z", "+00:00")).timestamp()
                self.assertLessEqual(before - 0.001, epoch)
                self.assertLessEqual(epoch, after + 0.001)
                clocks.append(expanded)
            self.assertEqual(clocks[0], clocks[1])
            self.assertEqual(lines[2], "//scu$deck_version")
            return clocks[0]

        before = time.time()
        self.run_scu("expand_deck", "main", "expanded")
        check_expanded(self.root / "expanded", before, time.time())
        output = self.root / "bulk"
        output.mkdir()
        before = time.time()
        self.run_scu("expand_modified_decks", "1.1", output)
        clock = check_expanded(output / "main", before, time.time())
        self.assertEqual((output / "other").read_text().split()[-1], clock)
        self.run_scu("extract_deck", "main", "raw")
        self.assertEqual((self.root / "raw").read_bytes(), source)

    def test_macro_scanner_preserves_boundaries_and_source_bytes(self):
        ordinary = b"ordinary source with spaces \x00\xff " * 8192
        unchanged = (b"XSCU$DATE x$SCU_TIME SCU$DATE_SUFFIX $SCU_TIME2 "
                     b"SCU$Date SCU$ $SCU")
        source = (
            b"//SCU$LIBRARY_VERSION\r\n"
            + ordinary + b"[$SCU_VERSION]\r"
            + unchanged + b"\n"
            + b"SCU$LAST_MODIFIED_DATE_TIME SCU$VERSION$SCU_VERSION\n"
            + b"SCU$DECK_VERSION"
        )
        self.store("main", source)
        modified = self.read_library()["revisions"][0]["modified_utc"].encode()

        self.run_scu("expand_deck", "main", "expanded")
        self.assertEqual(
            (self.root / "expanded").read_bytes(),
            b"1.0\r\n"
            + ordinary + b"[1.0]\r"
            + unchanged + b"\n"
            + modified + b" 1.0$SCU_VERSION\n"
            + b"1.0-0.000",
        )

    def test_macro_scanner_skips_long_plain_text_efficiently(self):
        self.store("main", b"x" * (24 * 1024 * 1024) + b" SCU$VERSION\n")

        def user_cpu_time(command, output):
            before = resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime
            self.run_scu(command, "main", output)
            return resource.getrusage(resource.RUSAGE_CHILDREN).ru_utime - before

        # Extraction controls for decoding and checksum costs on the same host.
        # Child user CPU time avoids counting waits for output writes.
        extract = user_cpu_time("extract_deck", "raw")
        expand = user_cpu_time("expand_deck", "expanded")
        self.assertLess(expand, 4 * extract + 0.05,
                        f"Expansion used {expand:.3f}s of CPU versus {extract:.3f}s for extraction")

    def test_snapshot_commands_report_and_audit_the_resolved_snapshot(self):
        source = b"'SCU$VERSION'\n"
        self.store("main.pas", source)
        self.store("shared.inc", b"shared")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.store("extra.inc", b"extra")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.2")

        cases = (
            ((), "1.2", 3, "extra.inc\t1.1-0.000\nmain.pas\t1.0-0.000\nshared.inc\t1.0-0.000\n"),
            (("version=1.0",), "1.0", 2, "main.pas\t1.0-0.000\nshared.inc\t1.0-0.000\n"),
            (("revision=1",), "1.0", 1, "main.pas\t1.0-0.000\n"),
            (("revision=3",), "1.1", 3, "extra.inc\t1.1-0.000\nmain.pas\t1.0-0.000\nshared.inc\t1.0-0.000\n"),
        )
        for selectors, version, revision, listing in cases:
            for command in ("display_deck_list", "extract_deck", "expand_deck"):
                with self.subTest(command=command, selectors=selectors):
                    arguments = () if command == "display_deck_list" else ("main.pas", "output")
                    result = subprocess.run(
                        [SCU, command, *arguments, *selectors], cwd=self.root,
                        capture_output=True, text=True, timeout=20,
                    )
                    self.assertEqual(result.returncode, 0, result.stderr)
                    self.assertEqual(result.stderr, f"Using version {version}, library revision {revision}.\n")
                    self.assertEqual(result.stdout, listing if command == "display_deck_list" else "")
                    begin, end = [
                        json.loads(line.split(b" ", 1)[1])
                        for line in self.audit_lines()[-2:]
                    ]
                    self.assertEqual(begin["command"], command)
                    if not selectors:
                        self.assertEqual(begin["options"], {"build": "yes"} if command == "expand_deck" else {})
                    self.assertTrue(end["success"])
                    self.assertEqual(end["snapshot"], {"version": version, "library_revision": revision})
                    if command == "extract_deck":
                        self.assertEqual((self.root / "output").read_bytes(), source)
                    elif command == "expand_deck":
                        self.assertEqual((self.root / "output").read_text(), f"'{version}'\n")

        missing_cases = (
            ((), "1.2", 3, "in version 1.2"),
            (("version=1.0",), "1.0", 2, "in version 1.0"),
            (("r=1",), "1.0", 1, "at revision 1"),
        )
        for selectors, version, revision, location in missing_cases:
            for command in ("extract_deck", "expand_deck"):
                with self.subTest(command=command, missing=True, selectors=selectors):
                    message = f'Deck "missing" does not exist {location}.'
                    self.run_scu(command, "missing", "output", *selectors, error=message)
                    end = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
                    self.assertFalse(end["success"])
                    self.assertEqual(end["detail"], message)
                    self.assertEqual(end["snapshot"], {"version": version, "library_revision": revision})
        self.run_scu("display_deck_list", "version=9.0", error="does not exist")
        end = json.loads(self.audit_lines()[-1].split(b" ", 1)[1])
        self.assertFalse(end["success"])
        self.assertNotIn("snapshot", end)
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

    def test_header_configures_editor_and_preserves_old_comment_prefix(self):
        self.run_scu("configure", "--comment-prefix", "#", "--editor", '["true"]')
        self.store("demo", b"#SCU$VERSION\n")
        self.assertEqual(self.run_scu("edit_deck", "demo"), "No changes to demo")
        self.assertEqual(len(self.read_library()["revisions"]), 1)
        editor = self.root / "test editor"
        editor.write_text('#!/bin/sh\nprintf "%s\\n" "$1" >> "$2"\n')
        editor.chmod(0o700)
        self.run_scu("configure", "--editor", json.dumps([str(editor), "saved text"]))
        self.assertEqual(self.run_scu("edit_deck", "demo"),
                         "demo version 1.0 revision 0.001, deck version 1.0-0.001")
        self.run_scu("lock_version")
        self.run_scu("edit_deck", "demo", error="is locked")
        self.run_scu("start_version", "1.1")
        self.run_scu("edid", "noot", error='Deck "noot" does not exist in version 1.1.')
        self.run_scu("configure", "--comment-prefix", "//", "--editor", '["false"]')
        self.run_scu("edit_deck", "demo", error="exit status 1")
        self.run_scu("expand_deck", "demo", "output", "--version", "1.0")
        self.assertEqual((self.root / "output").read_bytes(), b"1.0\nsaved text\n")
        header = json.loads(self.run_scu("show_library"))
        self.assertEqual(header["current_version"], "1.1")
        self.assertEqual(header["comment_prefix"], "//")
        self.assertEqual(header["editor"], ["false"])
        self.assertTrue(header["versions"][0]["locked"])
        self.assertEqual(header["versions"][0]["comment_prefix"], "#")
        self.assertEqual([entry["comment_prefix"] for entry in self.read_library()["revisions"]], ["#", "#"])

    def test_nested_copy_uses_each_decks_comment_prefix_at_the_selected_snapshot(self):
        main = b"//SCU_COPY shared.inc\n"
        self.store("main.pas", main)
        (self.root / "initial").write_bytes(b"#SCU$VERSION\n#SCU_COPY leaf.inc\n")
        self.run_scu("create_deck", "shared.inc", "from_file=initial", "comment_prefix=#")
        self.store("leaf.inc", b"!SCU$VERSION\n", "--cp", "!")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.run_scu("configure_library", "--comment-prefix", ";")
        self.store("main.pas", main)
        self.store("shared.inc", b"#SCU_COPY leaf.inc\n#SCU$VERSION\nretained\n")
        self.store("shared.inc", b";SCU$VERSION\n;SCU_COPY leaf.inc\nchanged\n", "--comment-prefix", ";")

        for selectors, expected in (
            (("version=1.0",), b"1.0\n1.0\n"),
            (("revision=5",), b"1.1\n1.1\nretained\n"),
            ((), b"1.1\n1.1\nchanged\n"),
            (("--comment-prefix", "//"), b";1.1\n;SCU_COPY leaf.inc\nchanged\n"),
        ):
            with self.subTest(selectors=selectors):
                self.run_scu("expand_deck", "main.pas", "expanded", *selectors)
                self.assertEqual((self.root / "expanded").read_bytes(), expected)
        (self.root / "bulk").mkdir()
        self.run_scu("expand_modified_decks", "1.1", "bulk")
        self.assertEqual((self.root / "bulk/main.pas").read_bytes(), b"1.1\n1.1\nchanged\n")
        self.assertEqual(self.run_scu("expmd"), "Wrote 2 deck(s) for version 1.1")
        self.assertEqual((self.root / "main.pas").read_bytes(), b"1.1\n1.1\nchanged\n")
        self.assertEqual([entry["comment_prefix"] for entry in self.read_library()["revisions"]],
                         ["//", "#", "!", "//", "#", ";"])
        self.run_scu("create_deck", "invalid", "--comment-prefix", "", error="Expected a nonempty comment prefix")

    def test_legacy_deck_without_comment_prefix_uses_the_selected_version_default(self):
        self.run_scu("configure_library", "--comment-prefix", "#")
        self.store("legacy", b"#SCU$VERSION\n")
        document = self.read_library()
        del document["revisions"][0]["comment_prefix"]
        self.write_library(document)
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.run_scu("configure_library", "--comment-prefix", "//")
        unchanged = self.read_library()
        self.run_scu("expand_deck", "legacy", "older", "version=1.0")
        self.run_scu("expand_deck", "legacy", "current")
        self.assertEqual((self.root / "older").read_bytes(), b"1.0\n")
        self.assertEqual((self.root / "current").read_bytes(), b"#1.1\n")
        self.assertEqual(self.read_library(), unchanged)

    def test_bad_deck_and_copy_failure_leave_existing_output_intact(self):
        source = b"\x00\xff\r\n"
        self.store("binary", source)
        self.run_scu("extract_deck", "binary", "output")
        doc = self.read_library()
        self.assertEqual(doc["revisions"][0]["sha1"], hashlib.sha1(source).hexdigest())
        doc["revisions"][0]["sha1"] = "0" * 40
        self.write_library(doc)
        self.run_scu("extract_deck", "binary", "output", error="SHA-1")
        self.store("cycle", b"//SCU_COPY cycle\n")
        self.run_scu("expand_deck", "cycle", "output", error="COPY cycle")
        self.store("missing", b"//SCU_COPY unknown\n")
        self.run_scu("expand_deck", "missing", "output", "version=1.0",
                     error='missing:1: Deck "unknown" does not exist in version 1.0.')
        self.run_scu("expand_deck", "missing", "output", "revision=3",
                     error='missing:1: Deck "unknown" does not exist at revision 3.')
        self.assertEqual((self.root / "output").read_bytes(), source)

    def test_audit_detects_modified_records_and_checkpoint_rollback(self):
        self.run_scu("extract_deck", "missing", "output", error="does not exist")
        checkpoint = self.run_scu("verify_audit").split("head=")[1]
        self.store("empty", b"")
        self.run_scu("verify_audit", "--head", checkpoint)
        records = self.audit_lines()
        failed = json.loads(records[3].split(b" ", 1)[1])
        self.assertFalse(failed["success"])
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            database.execute("DELETE FROM audit_records WHERE sequence > 3")
            self.run_scu("verify_audit", error="does not match the audit log")
            self.run_scu("verify_audit", "--head", checkpoint, error="Saved audit head")
            database.executemany("INSERT INTO audit_records (sequence, line) VALUES (?, ?)", (
                (index, line.decode()) for index, line in enumerate(records[3:], start=4)
            ))
            database.execute("UPDATE audit_records SET line = replace(line, ?, ?) WHERE sequence = 5",
                             ('"empty"', '"other"'))
        self.run_scu("verify_audit", error="digest mismatch")
        self.run_scu("store_deck", "other", "input", error="digest mismatch")

    def test_one_shot_commands_reuse_audit_state_and_full_verification_reads_the_prefix(self):
        self.run_scu("list_versions")
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
            self.run_scu("list_versions")
            last, = database.execute("SELECT line FROM audit_records WHERE sequence = 6").fetchone()
            self.assertEqual(database.execute("SELECT record_count, head FROM audit_state").fetchone(),
                             (6, last[:64]))
        self.run_scu("verify_audit_trail", error="Audit digest mismatch at record 1")

    def test_audit_state_is_seeded_for_an_existing_library(self):
        self.run_scu("list_versions")
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
            self.run_scu("list_versions")
            self.assertEqual(database.execute("SELECT record_count FROM audit_state").fetchone(), (6,))
            database.execute("UPDATE audit_state SET head = ?", ("0" * 64,))
        self.run_scu("list_versions", error="Stored audit state does not match the audit log")
        self.run_scu("verify_audit_trail", error="Stored audit state does not match the audit log")

    def test_show_history_lists_expanded_commands_and_accepts_a_line_count(self):
        for index in range(1, 22):
            self.run_scu("cred", f"deck-{index}")
        self.run_scu("ddl", "v=1.0")
        self.run_scu("extd", "dn=deck-21", "o=output copy")
        before = self.audit_lines()
        history = self.run_scu("show_history").splitlines()
        self.assertEqual(len(history), 20)
        self.assertEqual(history[0], 'create_deck deck_name=deck-4 from_file=""')
        self.assertEqual(history[-2:], [
            "display_deck_list version=1.0",
            'extract_deck deck_name=deck-21 output_file="output copy"',
        ])
        self.assertEqual(self.run_scu("shoh", "2").splitlines(), history[-2:])
        self.assertEqual(self.run_scu("show_history", "nl=1"), history[-1])
        self.run_scu("show_history", "0", error="Expected a positive number_of_lines")
        self.assertEqual(self.audit_lines(), before)

    def test_verify_audit_detects_changed_sqlite_payload(self):
        original_db = self.root / "original.sqlite"
        replacement_db = self.root / "replacement.sqlite"
        source = self.root / "source"
        for database, contents in ((original_db, b"original"), (replacement_db, b"replacement")):
            self.run_scu(database, "init")
            source.write_bytes(contents)
            self.run_scu(database, "store_deck", "main", source)
        head = self.run_scu(original_db, "verify_audit").split("head=")[1]
        with closing(sqlite3.connect(replacement_db)) as connection:
            payload, = connection.execute("SELECT payload FROM deck_revisions").fetchone()
        with closing(sqlite3.connect(original_db, isolation_level=None)) as connection:
            connection.execute("UPDATE deck_revisions SET payload = ? WHERE sequence = 1", (payload,))
        self.run_scu(original_db, "verify_audit", "head=" + head,
                     error="Library revision 1 does not match the audit log")
        with closing(sqlite3.connect(original_db, isolation_level=None)) as connection:
            connection.execute("UPDATE deck_revisions SET payload = json_set(?, '$.size', 1)", (payload,))
        self.run_scu(original_db, "extd", "main", "tampered-output", error="size")
        with closing(sqlite3.connect(original_db, isolation_level=None)) as connection:
            connection.execute("UPDATE deck_revisions SET payload = json_set(?, '$.sha1', ?)", (payload, "0" * 40))
        self.run_scu(original_db, "extd", "main", "tampered-output", error="SHA-1")

    def test_interactive_audit_detects_changes_from_other_processes(self):
        for mode in ("delete", "wal"):
            library = self.root / f"shared-{mode}.sqlite"
            self.run_scu(library, "init")
            with self.subTest(mode=mode), closing(sqlite3.connect(library, isolation_level=None)) as db:
                self.assertEqual(db.execute(f"PRAGMA journal_mode={mode}").fetchone(), (mode,))
                with self.terminal_session(library, TERM="dumb") as (process, terminal, read_until):
                    read_until(b"scu> ")
                    # An independent SCU writer extends the chain between commands.
                    self.run_scu(library, "list_versions")
                    head = self.run_scu(library, "verify_audit").split("head=")[1]
                    os.write(terminal, b"list_versions\n")
                    self.assertIn(b"1.0\topen", read_until(b"scu> "))
                    self.assertIn("records=8 interrupted=0", self.run_scu(library, "verify_audit", "head=" + head))

                    # Change an older record without changing the chain's tail.
                    original, = db.execute("SELECT line FROM audit_records WHERE sequence = 1").fetchone()
                    db.execute("UPDATE audit_records SET line = ? WHERE sequence = 1",
                               (original.replace('"phase"', '"phaze"', 1),))
                    os.write(terminal, b"list_versions\n")
                    self.assertIn(b"Audit digest mismatch at record 1", read_until(b"scu> "))
                    self.run_scu(library, "verify_audit_trail", error="Audit digest mismatch at record 1")

                    db.execute("UPDATE audit_records SET line = ? WHERE sequence = 1", (original,))
                    os.write(terminal, b"list_versions\n")
                    self.assertIn(b"1.0\topen", read_until(b"scu> "))
                    self.assertIn("records=10 interrupted=0", self.run_scu(library, "verify_audit", "head=" + head))
                    os.write(terminal, b"quit\n")
                    self.assertEqual(process.wait(timeout=5), 1)

    def test_review_source_and_expansion_limits(self):
        source = self.root / "oversized"
        with source.open("wb") as stream:
            stream.truncate(64 * 1024 * 1024 + 1)
        self.run_scu("store_deck", "large", source, error="File exceeds the 67108864-byte limit")
        self.store("empty", b"")
        self.store("many-copies", b"//SCU_COPY empty\n" * 10000)
        self.run_scu("expd", "many-copies", "too-many", error="Expansion exceeds 10000 deck visits")
        self.assertFalse((self.root / "too-many").exists())
        self.store("megabyte", b"x" * (1024 * 1024))
        self.store("large-expansion", b"//SCU_COPY megabyte\n" * 65)
        self.run_scu("expd", "large-expansion", "too-large", error="exceeds the 64 MiB output limit")
        self.assertFalse((self.root / "too-large").exists())
        commands = []
        for index in range(65):
            name = f"chain-{index}"
            data = f"//SCU_COPY chain-{index + 1}\n" if index < 64 else ""
            (self.root / name).write_text(data)
            commands.append(f"store_deck {name} {name}")
        result = subprocess.run([SCU], cwd=self.root, input="\n".join(commands) + "\n",
                                capture_output=True, text=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.run_scu("expd", "chain-0", "too-deep", error="COPY nesting exceeds 64 decks")
        self.assertFalse((self.root / "too-deep").exists())
        self.store("large-copy-line", b"//SCU_COPY " + b" " * (8 * 1024 * 1024) + b"empty\n")
        self.store("large-input", b"//SCU_COPY large-copy-line\n" * 32)
        self.run_scu("expd", "large-input", "too-much-input", error="exceeds 256 MiB of source input")
        self.assertFalse((self.root / "too-much-input").exists())

    def test_review_closed_pipe_still_records_the_command_outcome(self):
        self.store("main", b"original\n" * 3000)
        self.store("main", b"replacement\n" * 3000)
        with subprocess.Popen([SCU, "difd", "main"], cwd=self.root, stdout=subprocess.PIPE,
                              stderr=subprocess.DEVNULL) as process:
            process.stdout.close()
            self.assertEqual(process.wait(timeout=20), 1)
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

    def sqlite_state(self, database):
        metadata = database.execute("SELECT * FROM library").fetchall()
        revisions = database.execute("SELECT * FROM deck_revisions ORDER BY sequence").fetchall()
        audit = database.execute("SELECT * FROM audit_records ORDER BY sequence").fetchall()
        return metadata, revisions, audit

    def sqlite_build_times(self, path):
        with closing(sqlite3.connect(path)) as database:
            rows = database.execute("SELECT line FROM audit_records ORDER BY sequence")
            events = (json.loads(row[0][65:]) for row in rows)
            return [event["utc"] for event in events if event["phase"] == "build" and event["success"]]

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
        before_head = self.run_scu(path, "verify_audit")
        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            before = self.sqlite_state(database)
            state = database.execute("SELECT * FROM audit_state").fetchall()
            self.reject_sqlite_audit_outcome(database)
            self.run_scu(path, "create_deck", "staged",
                         error="injected audit write failure")
            self.assertEqual(self.sqlite_state(database), before)
            self.assertEqual(database.execute("SELECT * FROM audit_state").fetchall(), state)
            self.assertEqual(self.run_scu(path, "verify_audit"), before_head)
            database.execute("DROP TRIGGER reject_audit_outcome")
            self.run_scu(path, "create_deck", "staged")
            metadata, revisions, audit = self.sqlite_state(database)
            self.assertNotEqual(metadata, before[0])
            self.assertEqual([row[1] for row in revisions], ["existing", "staged"])
            self.assertEqual(audit[:-2], before[2])
            self.assertEqual(len(audit), len(before[2]) + 2)
            self.run_scu(path, "verify_audit", "--head", before_head.split("head=")[1])

    def test_sqlite_audit_failure_leaves_interactive_save_available_for_retry(self):
        path = self.root / "project.sqlite"
        self.run_scu(path, "initialize_library")
        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            with self.terminal_session(path, TERM="xterm") as (process, terminal, read_until):
                read_until(b"scu> ")
                os.write(terminal, b"create_deck staged\n")
                self.assertIn(b"staged version 1.0 revision 0.000", read_until(b"scu> "))
                before_head = self.run_scu(path, "verify_audit")
                before = self.sqlite_state(database)
                self.assertEqual(before[1], [])
                self.reject_sqlite_audit_outcome(database)

                os.write(terminal, b"save_library\n")
                self.assertIn(b"injected audit write failure", read_until(b"scu> "))
                self.assertEqual(self.sqlite_state(database), before)
                self.assertEqual(self.run_scu(path, "verify_audit"), before_head)

                database.execute("DROP TRIGGER reject_audit_outcome")
                os.write(terminal, b"save_library\n")
                self.assertIn(b"Saved library.", read_until(b"scu> "))
                metadata, revisions, audit = self.sqlite_state(database)
                self.assertNotEqual(metadata, before[0])
                self.assertEqual([row[1] for row in revisions], ["staged"])
                self.assertEqual(audit[:-2], before[2])
                self.assertEqual(len(audit), len(before[2]) + 2)
                self.run_scu(path, "verify_audit", "--head", before_head.split("head=")[1])
                os.write(terminal, b"quit\n")
                self.assertEqual(process.wait(timeout=5), 1)

    def test_sqlite_incremental_expansion_refreshes_only_changed_decks_and_copy_dependents(self):
        path = self.root / "project.sqlite"
        output = self.root / "expanded"
        other_output = self.root / "other output"
        alias = self.root / "alias"
        output.mkdir()
        other_output.mkdir()
        alias.symlink_to(output, target_is_directory=True)
        self.run_scu(path, "init")
        self.run_scu(path, "modify_library", 'build_command=printf "%s\\n" "$1" >> builds')
        source = self.root / "source"

        def store(name, data, *options):
            source.write_bytes(data)
            self.run_scu(path, "store_deck", name, source, *options)

        store("main", b"main\n  //SCU_COPY Middle\n")
        store("middle", b"\t#SCU_COPY leaf\r\n", "comment_prefix=#")
        store("leaf", b"first\n")
        store("standalone", b"unrelated\n")
        self.assertIn("Wrote 4 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.run_scu(path, "lock_version")
        self.run_scu(path, "start_version", "1.1")
        store("leaf", b"second\n")
        unrelated_inode = (output / "standalone").stat().st_ino
        self.assertIn("Wrote 3 deck(s)", self.run_scu(path, "expmd", "1.1", output))
        self.assertEqual((output / "main").read_bytes(), b"main\nsecond\n")
        self.assertEqual((output / "middle").read_bytes(), b"second\n")
        self.assertEqual((output / "standalone").stat().st_ino, unrelated_inode)
        inodes = {file.name: file.stat().st_ino for file in output.iterdir()}
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.1", alias))
        self.assertEqual({file.name: file.stat().st_ino for file in output.iterdir()}, inodes)
        self.assertIn("Wrote 3 deck(s)", self.run_scu(path, "expmd", "1.1", other_output))
        self.assertEqual({file.name for file in other_output.iterdir()}, {"main", "middle", "leaf"})

        store("standalone", b"changed alone\n")
        self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.1", output))
        self.assertEqual((output / "standalone").read_bytes(), b"changed alone\n")
        self.assertEqual({name: (output / name).stat().st_ino for name in ("main", "middle", "leaf")},
                         {name: inodes[name] for name in ("main", "middle", "leaf")})
        self.assertEqual((self.root / "builds").read_text().splitlines(),
                         [str(output), str(output), str(other_output), str(output)])
        first, _, alternate, latest = self.sqlite_build_times(path)
        self.assertEqual(self.run_scu(path, "display_expansion_checkpoints").splitlines(), [
            "Version\tOutput directory\tLast built library revision\tStatus\tLast successful build (UTC)"
            "\tCheckpoint library revision",
            f"1.0\t{output}\t4\tFull rebuild pending\t{first}\t4",
            f"1.1\t{output}\t6\tIncremental\t{latest}\t6",
            f"1.1\t{other_output}\t5\tIncremental\t{alternate}\t5",
        ])
        self.assertIn("Wrote 4 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.assertEqual((output / "main").read_bytes(), b"main\nfirst\n")
        self.assertIn("Wrote 4 deck(s)", self.run_scu(path, "expmd", "1.1", output))
        self.assertEqual((output / "main").read_bytes(), b"main\nsecond\n")

    def test_incremental_expansion_uses_copy_metadata_without_decoding_unrelated_decks(self):
        output = self.root / "expanded"
        output.mkdir()
        self.store("leaf", b"first\n")
        self.store("middle", b"  #SCU_COPY LEAF\r\n#SCU_COPY leaf\n", "comment_prefix=#")
        self.store("main", b"//SCU_COPY middle\n")
        self.store("unrelated", b"separate\n")
        self.assertIn("Wrote 4 deck(s)", self.run_scu("expmd", "1.0", output))
        unrelated_inode = (output / "unrelated").stat().st_ino
        self.store("leaf", b"second\n")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            metadata, = database.execute(
                "SELECT copy_metadata FROM deck_revisions WHERE deck_name = 'middle'"
            ).fetchone()
            self.assertEqual(json.loads(metadata), {"prefix": "#", "targets": ["leaf"]})
            # A graph walk that opens unrelated source would fail the checksum.
            database.execute("UPDATE deck_revisions SET payload = json_set(payload, '$.sha1', ?) "
                             "WHERE deck_name = 'unrelated'", ("0" * 40,))
            self.assertIn("Wrote 3 deck(s)", self.run_scu("expmd", "1.0", output))
            self.assertEqual((output / "main").read_bytes(), b"second\nsecond\n")
            self.assertEqual((output / "unrelated").stat().st_ino, unrelated_inode)
            self.run_scu("verify_audit_trail", error="Library revision 4 does not match the audit log")
            database.execute("UPDATE deck_revisions SET copy_metadata = json_set(copy_metadata, '$.targets', "
                             "json('[]')) WHERE deck_name = 'middle'")
        self.run_scu("verify_audit_trail", error="SQLite COPY metadata does not match revision 2")

    def test_copy_dependency_scan_handles_prefix_overrides_and_caches_older_revisions(self):
        output = self.root / "expanded"
        output.mkdir()
        self.store("leaf", b"first\n")
        self.store("parent", b"#SCU_COPY leaf\n")
        self.store("legacy", b"#SCU_COPY leaf\n", "comment_prefix=#")
        with closing(sqlite3.connect(self.library, isolation_level=None)) as database:
            # Recreate the stored shape of a revision predating the COPY index.
            database.execute("UPDATE deck_revisions SET payload = json_remove(payload, '$.copy_metadata'), "
                             "copy_metadata = NULL WHERE deck_name = 'legacy'")
            legacy, = database.execute("SELECT payload FROM deck_revisions WHERE deck_name = 'legacy'").fetchone()
            self.run_scu("expmd", "1.0", output, "comment_prefix=#")
            self.store("leaf", b"second\n")
            self.assertIn("Wrote 3 deck(s)", self.run_scu("expmd", "1.0", output, "comment_prefix=#"))
            self.assertEqual((output / "parent").read_bytes(), b"second\n")
            self.assertEqual((output / "legacy").read_bytes(), b"second\n")
            payload, metadata = database.execute(
                "SELECT payload, copy_metadata FROM deck_revisions WHERE deck_name = 'legacy'"
            ).fetchone()
            self.assertEqual(payload, legacy)
            self.assertEqual(json.loads(metadata), {"prefix": "#", "targets": ["leaf"]})
            original, = database.execute(
                "SELECT copy_metadata FROM deck_revisions WHERE deck_name = 'parent'"
            ).fetchone()
            self.assertEqual(json.loads(original), {"prefix": "//", "targets": []})

    def test_sqlite_expansion_checkpoint_advances_only_with_audited_build(self):
        path = self.root / "project.sqlite"
        output = self.root / "expanded"
        output.mkdir()
        self.run_scu(path, "init")
        self.run_scu(path, "create_deck", "main")
        self.assertEqual(self.run_scu(path, "disec"), "No expansion checkpoints.")
        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            self.run_scu(path, "modify_library", "build_command=test ! -e fail-build")
            self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output))
            first_build, = self.sqlite_build_times(path)
            first_checkpoint = f"1.0\t{output}\t1\tIncremental\t{first_build}\t1"
            source = self.root / "source"
            source.write_bytes(b"//SCU_COPY missing\n")
            self.run_scu(path, "store_deck", "main", source)
            self.run_scu(path, "expmd", "1.0", output, error='Deck "missing" does not exist')
            self.assertEqual((output / "main").read_bytes(), b"")
            source.write_bytes(b"second\n")
            self.run_scu(path, "store_deck", "main", source)
            self.run_scu(path, "expmd", "1.0", output, "build=no")
            self.assertEqual((output / "main").read_bytes(), b"second\n")
            self.assertEqual(database.execute("SELECT revision FROM expansion_checkpoints").fetchone(), (1,))

            failure = self.root / "fail-build"
            failure.touch()
            self.run_scu(path, "expmd", "1.0", output, error="Build command failed")
            self.assertEqual(database.execute("SELECT revision FROM expansion_checkpoints").fetchone(), (1,))
            self.assertEqual(self.run_scu(path, "disec").splitlines()[-1], first_checkpoint)
            failure.unlink()
            database.execute("""
                CREATE TRIGGER reject_build_audit BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'build'
                 AND EXISTS (SELECT 1 FROM expansion_checkpoints WHERE revision = 3)
                BEGIN
                    SELECT RAISE(ABORT, 'injected build audit failure');
                END
            """)
            self.run_scu(path, "expmd", "1.0", output, error="injected build audit failure")
            self.assertEqual(database.execute("SELECT revision FROM expansion_checkpoints").fetchone(), (1,))
            self.assertEqual(self.run_scu(path, "disec").splitlines()[-1], first_checkpoint)
            database.execute("DROP TRIGGER reject_build_audit")
            self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output))
            self.assertEqual(database.execute("SELECT revision FROM expansion_checkpoints").fetchone(), (3,))
            latest_build = self.sqlite_build_times(path)[-1]
            self.assertEqual(self.run_scu(path, "disec").splitlines()[-1],
                             f"1.0\t{output}\t3\tIncremental\t{latest_build}\t3")
            self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))
            events = [json.loads(row[0][65:]) for row in database.execute("SELECT line FROM audit_records")]
            self.assertEqual([event["success"] for event in events if event["phase"] == "build"],
                             [True, False, True])
        self.assertIn("interrupted=0", self.run_scu(path, "verify_audit"))

    def test_sqlite_expansion_checkpoints_success_without_a_build_command(self):
        path = self.root / "project.sqlite"
        output = self.root / "expanded"
        output.mkdir()
        source = self.root / "source"
        self.run_scu(path, "init")
        self.run_scu(path, "create_deck", "main")
        self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        first = f"1.0\t{output}\tNone\tIncremental\tNone\t1"
        self.assertEqual(self.run_scu(path, "disec").splitlines()[-1], first)
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        unchanged_inode = (output / "main").stat().st_ino

        source.write_bytes(b"//SCU_COPY missing\n")
        self.run_scu(path, "store_deck", "other", source)
        self.run_scu(path, "expmd", "1.0", output, error='Deck "missing" does not exist')
        self.assertEqual(self.run_scu(path, "disec").splitlines()[-1], first)
        source.write_bytes(b"new deck\n")
        self.run_scu(path, "store_deck", "other", source)
        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            database.execute("""
                CREATE TRIGGER reject_expansion_audit BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
                 AND EXISTS (SELECT 1 FROM expansion_checkpoints WHERE revision = 3 AND build_pending = 1)
                BEGIN
                    SELECT RAISE(ABORT, 'injected expansion audit failure');
                END
            """)
            before_head = self.run_scu(path, "verify_audit")
            self.run_scu(path, "expmd", "1.0", output, error="injected expansion audit failure")
            self.assertEqual(self.run_scu(path, "verify_audit"), before_head)
            self.assertEqual(self.run_scu(path, "disec").splitlines()[-1], first)
            database.execute("DROP TRIGGER reject_expansion_audit")

        self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output, "build=no"))
        self.assertEqual((output / "other").read_bytes(), b"new deck\n")
        self.assertEqual((output / "main").stat().st_ino, unchanged_inode)
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.assertEqual(self.sqlite_build_times(path), [])

        self.run_scu(path, "modify_library", 'build_command=cat "$1/other" > built-source')
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output, "build=no"))
        self.assertFalse((self.root / "built-source").exists())
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.assertEqual((self.root / "built-source").read_bytes(), b"new deck\n")
        built, = self.sqlite_build_times(path)
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.assertEqual(self.sqlite_build_times(path), [built])

        self.run_scu(path, "modify_library", "--build_command", "")
        self.run_scu(path, "create_deck", "third")
        self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.assertEqual(self.run_scu(path, "disec").splitlines()[-1],
                         f"1.0\t{output}\t3\tIncremental\t{built}\t4")

    def test_sqlite_reset_expansion_checkpoint_rebuilds_only_the_selected_batch(self):
        path = self.root / "project.sqlite"
        output = self.root / "expanded"
        other_output = self.root / "other output"
        alias = self.root / "alias"
        output.mkdir()
        other_output.mkdir()
        alias.symlink_to(output, target_is_directory=True)
        self.run_scu(path, "init")
        self.run_scu(path, "modify_library", "build_command=test ! -e fail-build")
        self.assertIn("No expansion checkpoint", self.run_scu(path, "resec", "1.0", output))
        self.run_scu(path, "cred", "inherited")
        self.run_scu(path, "lock_version")
        self.run_scu(path, "start_version", "1.1")
        self.run_scu(path, "cred", "new")
        self.run_scu(path, "expmd", "1.1", output)
        self.run_scu(path, "expmd", "1.1", other_output)
        self.assertEqual({file.name for file in output.iterdir()}, {"new"})
        before = self.run_scu(path, "disec")
        before_head = self.run_scu(path, "verify_audit")

        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            database.execute("""
                CREATE TRIGGER reject_reset_audit BEFORE INSERT ON audit_records
                WHEN json_extract(substr(NEW.line, 66), '$.phase') = 'end'
                 AND EXISTS (SELECT 1 FROM expansion_checkpoints WHERE comment_prefix IS NULL)
                BEGIN
                    SELECT RAISE(ABORT, 'injected reset audit failure');
                END
            """)
            self.run_scu(path, "resec", "1.1", alias, error="injected reset audit failure")
            self.assertEqual(self.run_scu(path, "verify_audit"), before_head)
            database.execute("DROP TRIGGER reject_reset_audit")
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.1", output))

        self.assertIn("Reset expansion checkpoint", self.run_scu(path, "resec", "v=1.1", f"od={alias}"))
        pending = before.replace(f"1.1\t{output}\t2\tIncremental", f"1.1\t{output}\t2\tFull rebuild pending")
        self.assertNotEqual(pending, before)
        self.assertEqual(self.run_scu(path, "disec"), pending)
        self.assertEqual({file.name for file in output.iterdir()}, {"new"})
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.1", other_output))
        self.assertIn("Wrote 2 deck(s)", self.run_scu(path, "expmd", "1.1", output, "build=no"))
        self.assertEqual({file.name for file in output.iterdir()}, {"inherited", "new"})
        self.assertEqual(self.run_scu(path, "disec"), pending)
        failure = self.root / "fail-build"
        failure.touch()
        self.run_scu(path, "expmd", "1.1", output, error="Build command failed")
        self.assertEqual(self.run_scu(path, "disec"), pending)
        failure.unlink()
        self.assertIn("Wrote 2 deck(s)", self.run_scu(path, "expmd", "1.1", output))
        first_build, other_build, rebuilt = self.sqlite_build_times(path)
        expected = before.replace(f"1.1\t{output}\t2\tIncremental\t{first_build}",
                                  f"1.1\t{output}\t2\tIncremental\t{rebuilt}")
        self.assertIn(f"1.1\t{other_output}\t2\tIncremental\t{other_build}\t2", expected.splitlines())
        self.assertEqual(self.run_scu(path, "disec"), expected)
        self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.1", output))

    def test_sqlite_expansion_migrates_existing_schema_and_refreshes_changed_prefix(self):
        path = self.root / "project.sqlite"
        output = self.root / "expanded"
        output.mkdir()
        self.run_scu(path, "init")
        with closing(sqlite3.connect(path, isolation_level=None)) as database:
            database.executescript("DROP TABLE expansion_checkpoints; PRAGMA user_version = 1;")
            self.run_scu(path, "verify_audit")
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (1,))
            self.run_scu(path, "modify_library", "build_command=true")
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (5,))
            source = self.root / "source"
            source.write_bytes(b"//SCU$VERSION\n")
            self.run_scu(path, "store_deck", "main", source)
            self.run_scu(path, "expmd", "1.0", output)
            database.executescript(
                "ALTER TABLE expansion_checkpoints DROP COLUMN build_pending; PRAGMA user_version = 2;"
            )
            self.run_scu(path, "verify_audit")
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (2,))
            self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))
            self.assertEqual(database.execute("PRAGMA user_version").fetchone(), (5,))
            self.assertEqual((output / "main").read_bytes(), b"1.0\n")
            self.run_scu(path, "expmd", "1.0", output, "comment_prefix=#", "build=no")
            self.assertEqual((output / "main").read_bytes(), b"//1.0\n")
            self.assertEqual(database.execute("SELECT revision FROM expansion_checkpoints").fetchone(), (1,))
            self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output))
            self.assertEqual((output / "main").read_bytes(), b"1.0\n")
            self.assertIn("Wrote 0 deck(s)", self.run_scu(path, "expmd", "1.0", output))

    def test_sqlite_expansion_build_checkpoints_the_snapshot_it_actually_expanded(self):
        path = self.root / "project.sqlite"
        output = self.root / "expanded"
        output.mkdir()
        self.run_scu(path, "init")
        self.run_scu(path, "create_deck", "main")
        (self.root / "source").write_bytes(b"edit during build\n")
        (self.root / "edit-during-build").touch()
        command = f"{shlex.quote(str(SCU))} {shlex.quote(str(path))}"
        (self.root / "build-script").write_text(
            'if [ -e edit-during-build ]; then\n'
            '  rm edit-during-build\n'
            f'  {command} expmd 1.0 "$1" > nested-output 2>&1 && exit 8\n'
            f'  {command} resec 1.0 "$1" > nested-reset 2>&1 && exit 9\n'
            f'  {command} store_deck main source\n'
            'fi\n'
        )
        self.run_scu(path, "modify_library", 'build_command=sh build-script "$1"')
        self.run_scu(path, "expmd", "1.0", output)
        self.assertIn("An expansion is already using output directory", (self.root / "nested-output").read_text())
        self.assertIn("An expansion is already using output directory", (self.root / "nested-reset").read_text())
        self.assertEqual((output / "main").read_bytes(), b"")
        with closing(sqlite3.connect(path)) as database:
            self.assertEqual(database.execute("SELECT revision FROM expansion_checkpoints").fetchone(), (1,))
        self.assertIn("Wrote 1 deck(s)", self.run_scu(path, "expmd", "1.0", output))
        self.assertEqual((output / "main").read_bytes(), b"edit during build\n")

    def test_sqlite_expansion_uses_saved_interactive_changes(self):
        output = self.root / "expanded"
        output.mkdir()
        path = output / "project.sqlite"
        self.run_scu(path, "init")
        self.run_scu(path, "modify_library", "build_command=true")
        source = self.root / "input"
        source.write_bytes(b"first\n")
        self.run_scu(path, "store_deck", "main", source)
        self.run_scu(path, "expmd", "1.0", output)
        self.run_scu(path, "lock_version")
        self.run_scu(path, "start_version", "1.1")
        source.write_bytes(b"second\n")
        with self.terminal_session(path, TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"store_deck main input\n")
            self.assertIn(b"main version 1.1 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"expmd\n")
            self.assertIn(b"Save the SQLite library before running expand_modified_decks.",
                          read_until(b"scu> "))
            self.assertEqual((output / "main").read_bytes(), b"first\n")
            os.write(terminal, b"savl\n")
            self.assertIn(b"Saved library.", read_until(b"scu> "))
            os.write(terminal, b"expmd\n")
            self.assertIn(b"Wrote 1 deck(s) for version 1.1", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 1)
        self.assertEqual((output / "main").read_bytes(), b"second\n")
        self.assertFalse((self.root / "main").exists())
        self.assertEqual(self.run_scu(path, "expmd", "1.1", output), "Wrote 0 deck(s) for version 1.1")
        self.assertIn(f"1.0\t{output}\t1\tFull rebuild pending", self.run_scu(path, "disec"))

    def test_deck_history_and_aliases_use_canonical_audit_names(self):
        self.store("Main.pas", b"first")
        self.store("shared.inc", b"unrelated")
        self.store("main.pas", b"second")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.2")
        self.store("main.pas", b"third")
        revisions = self.read_library()["revisions"]
        expected = "\n".join(
            f"{number}\t{version}\t{revisions[number - 1]['modified_utc']}\t"
            f"{version}-{revisions[number - 1]['deck_revision']}"
            for number, version in ((4, "1.2"), (3, "1.0"), (1, "1.0"))
        )
        for arguments in (
            ("display_deck", "deck_name=main.pas"),
            ("disd", "dn=main.pas"),
            ("disd", "main.pas"),
            ("DD", "DN=main.pas"),
        ):
            self.assertEqual(self.run_scu(*arguments), expected)
        self.run_scu("DD", "DN=", "main.pas", error="Too many arguments")
        listing = self.run_scu("display_deck_list", "--version", "1.1")
        self.assertEqual(self.run_scu("ddl", "v=1.1"), listing)
        self.assertEqual(self.run_scu("list_decks", "version=1.1"), listing)
        self.run_scu("disd", "dn=missing", error="does not exist")
        self.run_scu("dd", "main.pas", "dn=main.pas", error="Duplicate argument deck_name")

        records = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        displays = [event for event in records if event.get("command") == "display_deck"]
        self.assertEqual([event["parameters"] for event in displays],
                         [{"deck_name": "main.pas"}] * 4 + [{"deck_name": "missing"}])
        lists = [event for event in records if event.get("command") == "display_deck_list"]
        self.assertEqual([event["options"] for event in lists], [{"version": "1.1"}] * 3)
        self.run_scu("verify_audit")

    def test_diff_default_uses_prior_deck_revision_in_first_version(self):
        self.store("aap.c", b"first\n")
        self.run_scu("difd", error='Deck "aap.c" has no earlier revision')
        self.store("aap.c", b"second\n")
        self.store("other", b"unrelated\n")
        output = self.run_scu("difd", "dn=aap.c", "to=1.0-0.001")
        self.assertIn("--- aap.c@1.0-0.000\n+++ aap.c@1.0-0.001", output)
        self.assertIn("-first\n+second", output)

        (self.root / "edited").write_bytes(b"third\n")
        result = subprocess.run(
            [SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
            input="store_deck aap.c edited\ndisd\ndifd\nquit save_library=no\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "From deck version 1.0-0.001.\nTo deck version 1.0-0.002.\n")
        self.assertIn("--- aap.c@1.0-0.001\n+++ aap.c@1.0-0.002\n", result.stdout)
        self.assertIn("-second\n+third", result.stdout)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        outcome = events[-3]
        self.assertEqual(events[-4]["command"], "diff_deck")
        self.assertEqual(outcome["resolved_deck"], "aap.c")
        self.assertEqual(outcome["from_deck_version"], "1.0-0.001")
        self.assertEqual(outcome["to_deck_version"], "1.0-0.002")

    def test_diff_compares_raw_source_at_deck_versions(self):
        self.store("main.pas", b"//SCU_COPY old.inc\n' SCU$VERSION '\n")
        self.store("unrelated", b"other deck")
        self.run_scu("lock_version")
        current = "scu$current_deck_version"
        previous = "scu$previous_deck_version"
        self.run_scu("diff_deck", "main.pas", previous,
                     error="has no earlier revision to compare with")
        self.run_scu("start_version", "1.1")
        self.store("main.pas", b"//SCU_COPY new.inc\n' SCU$VERSION '\n")
        old, new = "1.0-0.000", "1.1-0.000"

        def audit_outcome():
            return json.loads(self.audit_lines()[-1].split(b" ", 1)[1])

        def check_endpoints(before, after, from_deck, to_deck):
            arguments = ["main.pas"]
            if after is not None:
                arguments.insert(0, f"to={after}")
            if before is not None:
                arguments.append(f"from={before}")
            result = subprocess.run(
                [SCU, "diff_deck", *arguments],
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
        result = subprocess.run(
            [SCU], cwd=self.root, capture_output=True, text=True, timeout=20,
            input="diff_deck main.pas\nquit\n",
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stderr, "From deck version 1.0-0.000.\nTo deck version 1.1-0.000.\n")
        self.assertEqual(result.stdout, output)
        self.assertEqual(self.run_scu("difd", "dn=main.pas", old, old), "")
        self.run_scu("lock_version")
        self.assertIn("-//SCU_COPY new.inc\n+//SCU_COPY old.inc\n",
                      check_endpoints(current, previous.upper(), new, old))
        self.run_scu("start_version", "1.2")
        self.assertEqual(check_endpoints(new, current, new, new), "")
        self.assertEqual(check_endpoints(previous, None, old, new), output)
        self.run_scu("diff_deck", "main.pas", old, "9.9-0.000", error='Version "9.9"')
        end = audit_outcome()
        self.assertFalse(end["success"])
        self.assertEqual(end["from_deck_version"], old)
        self.assertNotIn("to_deck_version", end)
        for selector in ("1.0", "2", "scu$current", "scu$previous"):
            self.run_scu("diff_deck", "main.pas", selector, error="Expected VERSION-REVISION")
        self.store("binary", b"\x00old")
        self.store("binary", b"\x00new")
        self.assertIn("Binary files binary@1.2-0.000 and binary@1.2-0.001 differ",
                      self.run_scu("diff_deck", "binary", "1.2-0.000", "1.2-0.001"))
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

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
                result = subprocess.run(
                    [SCU, "diff_deck", "source", old, new],
                    cwd=self.root, capture_output=True, timeout=20,
                    env=dict(os.environ, PATH="", TMPDIR=str(self.root / "unavailable")),
                )
                self.assertEqual(result.returncode, 0, result.stderr)
                headers = f"--- source@{old}\n+++ source@{new}\n".encode()
                self.assertEqual(result.stdout, headers + expected)

    def test_review_diff_preserves_scattered_hunks(self):
        lines = [f"line {index:05}\n".encode() for index in range(6500)]
        changed = lines.copy()
        for index in range(10, 6000, 10):
            changed[index] = f"changed {index:05}\n".encode()
        self.store("main", b"".join(lines))
        self.store("main", b"".join(changed))
        patch = self.run_scu("diff_deck", "main")
        self.assertEqual(sum(line.startswith("@@ ") for line in patch.splitlines()), 599)

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
                patch = self.run_scu("diff_deck", deck)
                self.assertEqual(sum(line.startswith("@@ ") for line in patch.splitlines()), expected)

    def test_typed_definitions_and_aliases_are_loaded_per_command(self):
        (self.root / "source with spaces").write_text("stored text")
        subprocess.run(
            ["sh", "-c", '"$1" store_deck dn=1.25 source_file="source with spaces"', "sh", SCU],
            cwd=self.root, check=True, capture_output=True, timeout=20,
        )
        self.run_scu("extd", "dn=1.25", "output_file=output with spaces", "--r", "1")
        self.assertEqual((self.root / "output with spaces").read_text(), "stored text")
        self.run_scu("ddl", "r=1.25", error="Expected integer value for revision")
        self.run_scu("ddl", "r=0x1", error="Expected integer value for revision")
        self.run_scu("ddl", "r=9223372036854775808", error="Expected integer value for revision")

        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        display = next(command for command in definitions["commands"]
                       if command["name"] == "display_deck")
        display["aliases"].append("show_deck_history")
        display["arguments"][0].update(type="float", aliases=["number"], value="scu$required")
        definitions["library_option"]["aliases"] = ["lib"]
        (self.root / "commands.json").write_text(json.dumps(definitions))
        self.assertIn("number", self.run_scu("display_command", "show_deck_history", executable=executable))
        self.assertIn("1\t1.0\t", self.run_scu("--lib", self.library, "show_deck_history",
                                               "number=1.25", executable=executable))
        self.run_scu("show_deck_history", "number=1,25", error="Expected float", executable=executable)
        self.run_scu("show_deck_history", "number=nan", error="Expected float", executable=executable)
        self.run_scu("show_deck_history", "dn=1.25", error="Expected float", executable=executable)
        self.assertEqual(self.run_scu("extd", "dn=1.25", "o=old-alias", executable=executable), "")

        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        extracts = [event for event in events if event.get("command") == "extract_deck"]
        self.assertEqual(extracts[-1]["parameters"], {"deck_name": "1.25", "output_file": "old-alias"})
        self.assertEqual(extracts[0]["options"], {"revision": "1"})

    def test_legacy_command_definitions_still_load(self):
        self.store("main.pas", b"source")
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = {
            "format": 1,
            "argument_aliases": {"dn": "deck_name", "r": "revision"},
            "commands": [
                {"name": "help", "summary": "Show commands.", "arguments": [], "options": {}},
                {"name": "init", "summary": "Initialize a library.", "arguments": [], "options": {}},
                {"name": "extract_deck", "aliases": ["extd"], "summary": "Extract source.",
                 "arguments": ["deck_name", "output"], "options": {"revision": "REV"}},
            ],
        }
        (self.root / "commands.json").write_text(json.dumps(definitions))
        self.assertEqual(self.run_scu("-h", executable=executable).splitlines(), [
            "extract_deck, extd  Extract source.",
            "help, -h, --help    Show commands.",
            "init                Initialize a library.",
        ])
        self.run_scu("extd", "dn=main.pas", "output=copy", "r=1", executable=executable)
        self.assertEqual((self.root / "copy").read_bytes(), b"source")
        self.run_scu("ln=legacy", "init", executable=executable)
        self.assertIn("records=2", self.run_scu("legacy", "verify_audit"))
        self.run_scu("ln=legacy", "initialize_library", error="previously initialized")

    def test_library_first_and_named_invocation_share_the_same_library(self):
        name = "project library"
        self.run_scu(f"ln={name}", "init")
        (self.root / "source").write_text("project source")
        self.run_scu(f"ln={name}", "store_deck", "main.pas", "source")
        self.assertEqual(self.run_scu(f"library_name={name}", "ddl"), "main.pas\t1.0-0.000")
        self.assertEqual(self.run_scu("--library", name, "ddl"), "main.pas\t1.0-0.000")
        self.assertEqual(self.run_scu("--ln", name, "ddl"), "main.pas\t1.0-0.000")
        self.run_scu("ln=", name, "ddl", error="Expected a library name")
        self.assertEqual(self.run_scu("ddl"), "")
        self.run_scu("ln=", error="Expected a library name")
        self.run_scu("ln=init", "init")
        self.assertTrue((self.root / "init").is_file())

    def test_interactive_session_uses_quoted_arguments_and_logs_commands(self):
        (self.root / "source with spaces").write_text("interactive source")
        result = subprocess.run(
            [SCU, "ln=interactive library"], cwd=self.root, capture_output=True, text=True,
            input=(
                '\ninit\nstore_deck dn=main.pas source_file="source with spaces"\n'
                'extd dn=main.pas output_file="unclosed\n'
                "extd dn=main.pas output_file='working copy.pas'\n"
                "ddl\nq\nstore_deck ignored 'source with spaces'\n"
            ),
            timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        self.assertIn("Unclosed quote", result.stderr)
        self.assertIn("main.pas\t1.0-0.000", result.stdout)
        self.assertNotIn("scu>", result.stdout + result.stderr)
        self.assertEqual((self.root / "working copy.pas").read_text(), "interactive source")
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines(self.root / "interactive library")]
        commands = [event["command"] for event in events if event["phase"] == "begin"]
        self.assertEqual(commands, ["initialize_library", "store_deck", "extract_deck", "display_deck_list",
                                    "quit_session"])
        extract = next(event for event in events if event.get("command") == "extract_deck")
        self.assertEqual(extract["parameters"],
                         {"deck_name": "main.pas", "output_file": "working copy.pas"})
        self.assertIn("records=10 interrupted=0",
                      self.run_scu("interactive library", "verify_audit"))
        result = subprocess.run(
            [SCU], cwd=self.root, capture_output=True, text=True, input="list_versions", timeout=20
        )
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(result.stdout, "1.0\topen\t0\t0\n")

    def test_interactive_missing_library_points_to_initialization(self):
        empty = self.root / "empty"
        empty.mkdir()
        result = subprocess.run(
            [SCU], cwd=empty, input="disdl\ninil\ndisdl\nquit\n",
            capture_output=True, text=True, timeout=20,
        )
        self.assertEqual(result.returncode, 1, result.stderr)
        database = empty / "library.sqlite"
        self.assertIn(f'Library "{database}" does not exist.', result.stderr)
        self.assertIn("Use initialize_library to create it.", result.stderr)
        self.assertNotIn("Could not open audit log", result.stderr)
        self.assertIn("Initialized version 1.0", result.stdout)
        self.assertIn("Using version 1.0, library revision 0.", result.stderr)
        self.assertFalse((empty / "library.json").exists())
        self.assertFalse((empty / "library.sqlite.audit").exists())
        self.assertEqual((empty / "library.sqlite.lock").stat().st_size, 0)
        with closing(sqlite3.connect(database)) as connection:
            self.assertEqual(connection.execute("SELECT count(*) FROM audit_records").fetchone(), (4,))
        self.assertIn("records=4", self.run_scu(database, "verify_audit"))

    def test_json_files_are_not_opened_as_libraries(self):
        legacy = self.root / "library.json"
        legacy.write_text('{"format":1,"header":{},"revisions":[]}')
        original = legacy.read_bytes()
        self.run_scu(legacy, "ddl", error="file is not a database")
        self.run_scu(legacy, "init", error="file is not a database")
        self.assertEqual(legacy.read_bytes(), original)
        self.assertEqual(self.run_scu("ddl"), "")
        self.assertFalse(legacy.with_suffix(".json.audit").exists())

    def test_interactive_save_and_quit_control_when_library_changes_are_written(self):
        original = self.read_library()
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"create_deck saved\n")
            self.assertIn(b"saved version 1.0 revision 0.000", read_until(b"scu> "))
            self.assertEqual(self.read_library(), original)
            os.write(terminal, b"dd sa\t\n")
            self.assertIn(b"1\t1.0\t", read_until(b"scu> "))
            os.write(terminal, b"savl\n")
            self.assertIn(b"Saved library.", read_until(b"scu> "))
            saved = self.read_library()
            self.assertEqual(self.read_library()["revisions"][0]["deck"], "saved")

            os.write(terminal, b"create_deck discarded\n")
            self.assertIn(b"discarded version 1.0 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"quit save_library=maybe\n")
            self.assertIn(b"Expected yes/y or no/n", read_until(b"scu> "))
            os.write(terminal, b"quit save_library=n\t\n")
            read_until(b"Discarded unsaved library changes.")
            self.assertEqual(process.wait(timeout=5), 1)
        self.assertEqual(self.read_library(), saved)

        result = subprocess.run([SCU], cwd=self.root, input="create_deck automatic\nquit\n",
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertIn("Saved library.", result.stdout)
        self.assertEqual([entry["deck"] for entry in self.read_library()["revisions"]], ["saved", "automatic"])
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        self.assertTrue(any(event.get("pending_save") for event in events))
        self.assertEqual(events[-2]["parameters"], {"save_library": "yes"})
        self.assertEqual(events[-1]["snapshot"], {"version": "1.0", "library_revision": 2})
        result = subprocess.run([SCU], cwd=self.root, input="create_deck end-of-input\n",
                                text=True, capture_output=True, timeout=20)
        self.assertEqual(result.returncode, 0, result.stderr)
        self.assertEqual(self.read_library()["revisions"][-1]["deck"], "end-of-input")

    def test_interactive_save_refuses_to_overwrite_a_concurrent_update(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"create_deck staged\n")
            self.assertIn(b"staged version 1.0 revision 0.000", read_until(b"scu> "))
            self.run_scu("create_deck", "external")
            os.write(terminal, b"quit y\n")
            self.assertIn(b"saved library changed outside this session", read_until(b"scu> "))
            os.write(terminal, b"\x04")
            self.assertIn(b"saved library changed outside this session", read_until(b"scu> "))
            os.write(terminal, b"ddl\n")
            self.assertIn(b"staged\t1.0-0.000", read_until(b"scu> "))
            os.write(terminal, b"q sl=N\n")
            read_until(b"Discarded unsaved library changes.")
            self.assertEqual(process.wait(timeout=5), 1)
        self.assertEqual([entry["deck"] for entry in self.read_library()["revisions"]], ["external"])
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

    def test_command_help_and_required_argument_prompts(self):
        listing = self.run_scu("discl")
        self.assertEqual(listing, self.run_scu("help"))
        self.assertEqual(listing, self.run_scu("--help"))
        self.assertRegex(listing, r"(?m)^extract_deck, extd +Write the original source bytes to a file\.$")
        self.assertNotIn("output_file", listing)
        help_text = self.run_scu("display_command", "command_name=extd")
        self.assertEqual(help_text.splitlines()[0], "extract_deck, extd")
        self.assertIn("deck_name (deck, dn) : string = scu$last_modified_deck", help_text)
        self.assertIn("including COPY directives and macro text", help_text)
        self.assertIn("output_file (o, output) : string = scu$deck_name\n"
                      "    Path to write the original source bytes.", help_text)
        self.assertIn("--revision (r) : integer = scu$optional\n"
                      "    Library-wide snapshot after the specified saved change. Revision 0 is empty.",
                      help_text)
        self.assertIn("--version (v) : string = scu$optional\n"
                      "    Latest snapshot of a named version, including inherited decks.", help_text)
        self.run_scu("display_command", error="Missing required argument command_name")
        self.run_scu("display_command", "command_name=", error='Unknown command ""')

        with self.terminal_session(TERM="dumb") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"display_command\n")
            self.assertIn(b"command_name (cn) : string = scu$required", read_until(b"command_name= "))
            os.write(terminal, b"extd\n")
            self.assertIn(help_text.replace("\n", "\r\n").encode(), read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_command_catalog_is_alphabetically_sorted(self):
        catalog = Path(__file__).resolve().parents[1] / "commands.json"
        definitions = json.loads(catalog.read_bytes())
        commands = definitions["commands"]
        command_names = [command["name"] for command in commands]
        self.assertEqual(command_names, sorted(command_names), "commands by full name")

        library_aliases = definitions["library_option"]["aliases"]
        self.assertEqual(library_aliases, sorted(library_aliases), "library option aliases")
        for command in commands:
            name = command["name"]
            option_names = [option["name"] for option in command["options"]]
            with self.subTest(command=name):
                self.assertEqual(option_names, sorted(option_names), "options by full name")
                self.assertEqual(command["aliases"], sorted(command["aliases"]), "command aliases")
            # Positional arguments are listed in parsing order. Check only their aliases.
            for parameter in command["arguments"] + command["options"]:
                with self.subTest(command=name, parameter=parameter["name"]):
                    aliases = parameter["aliases"]
                    self.assertEqual(aliases, sorted(aliases), "parameter aliases")

    def test_format_commands_sorts_catalog_without_reordering_positional_arguments(self):
        project = Path(__file__).resolve().parents[1]
        catalog = json.loads((project / "commands.json").read_bytes())
        diff = next(command for command in catalog["commands"] if command["name"] == "diff_deck")
        diff["arguments"].reverse()
        expected = json.loads(json.dumps(catalog))

        catalog["library_option"]["aliases"].reverse()
        catalog["commands"].reverse()
        for command in catalog["commands"]:
            command["aliases"].reverse()
            command["options"].reverse()
            for parameter in command["arguments"] + command["options"]:
                parameter["aliases"].reverse()

        path = self.root / "commands.json"
        path.write_text(json.dumps(catalog), encoding="utf-8")
        formatter = [sys.executable, str(project / "tools/format_commands.py"), str(path)]
        subprocess.run(formatter, check=True, timeout=20)
        formatted = path.read_bytes()
        self.assertEqual(json.loads(formatted), expected)
        self.assertIn(b'"aliases": ["library_name", "ln"]', formatted)
        subprocess.run(formatter, check=True, timeout=20)
        self.assertEqual(path.read_bytes(), formatted)

    def test_format_commands_accepts_legacy_catalogs_without_aliases(self):
        path = self.root / "commands.json"
        formatter = Path(__file__).resolve().parents[1] / "tools/format_commands.py"
        for version in (1, 2):
            with self.subTest(version=version):
                if version == 1:
                    arguments = ["second", "first"]
                    options = {"z_option": "last", "a_option": "first"}
                else:
                    arguments = [{"name": "second"}, {"name": "first"}]
                    options = [{"name": "z_option"}, {"name": "a_option"}]
                catalog = {"format": version, "commands": [
                    {"name": "z_command", "arguments": arguments, "options": options},
                    {"name": "a_command", "arguments": [], "options": {} if version == 1 else []},
                ]}
                path.write_text(json.dumps(catalog))
                subprocess.run([sys.executable, formatter, path], check=True, timeout=20)
                first, last = json.loads(path.read_bytes())["commands"]
                self.assertEqual(first["name"], "a_command")
                self.assertEqual(last["arguments"], arguments)
                names = list(last["options"]) if version == 1 else [item["name"] for item in last["options"]]
                self.assertEqual(names, ["a_option", "z_option"])

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
        for command in commands:
            name = command["name"]
            self.assertRegex(name, r"^[a-z]+(?:_[a-z]+)+$")
            self.assertTrue(command["aliases"])
            help_text = self.run_scu("display_command", f"command_name={name}")
            self.assertEqual(help_text.splitlines()[:2],
                             [", ".join([name, *command["aliases"]]), command["summary"]])
            groups = command.get("exclusive_options", [])
            if groups:
                expected = ["Mutually exclusive options (choose at most one per group)"]
                expected.extend("  " + ", ".join(f"--{option}" for option in group) for group in groups)
                self.assertIn("\n".join(expected), help_text)
            else:
                self.assertNotIn("Mutually exclusive options", help_text)
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
            for index, parameter in enumerate(command["arguments"] + command["options"]):
                self.assertTrue(parameter["aliases"])
                for spelling in [parameter["name"], *parameter["aliases"]]:
                    self.assertNotIn(spelling.casefold(), parameter_names)
                    parameter_names.add(spelling.casefold())
                prefix = "" if index < len(command["arguments"]) else "--"
                value = parameter["value"]
                if isinstance(value, bool):
                    value = "yes" if value else "no"
                aliases = ", ".join(parameter["aliases"])
                signature = f"{prefix}{parameter['name']} ({aliases}) : {parameter['type']} = {value}"
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
        extract["options"][0]["value"] = 1
        extract["help_file"] = "extract.txt"
        (self.root / "extract.txt").write_text("Help loaded from a file.")
        (self.root / "commands.json").write_text(json.dumps(definitions))
        help_text = self.run_scu("display_command", "extd", executable=executable)
        self.assertIn("Help loaded from a file.", help_text)
        self.assertIn("output_file (o, output) : string = default output", help_text)
        self.assertIn("--revision (r) : integer = 1", help_text)
        self.run_scu("extd", "main.pas", executable=executable)
        self.assertEqual((self.root / "default output").read_bytes(), b"source")
        self.run_scu("extd", "main.pas", "output_file=override", executable=executable)
        self.assertEqual((self.root / "override").read_bytes(), b"source")
        (self.root / "default output").unlink()
        self.store("main.pas", b"updated")
        with self.terminal_session(TERM="dumb", executable=executable) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"extd main.pas\n")
            self.assertIn(b"output_file (o, output) : string = default output", read_until(b"output_file= "))
            os.write(terminal, b"\n")
            self.assertIn(b"--revision (r) : integer = 1", read_until(b"revision= "))
            os.write(terminal, b"\n")
            read_until(b"scu> ")
            os.write(terminal, b"extd main.pas\n")
            read_until(b"output_file= ")
            os.write(terminal, b"interactive override\n")
            read_until(b"revision= ")
            os.write(terminal, b"2\n")
            read_until(b"scu> ")
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual((self.root / "default output").read_bytes(), b"source")
        self.assertEqual((self.root / "interactive override").read_bytes(), b"updated")

    def test_format_two_presence_and_default_values_still_work(self):
        self.store("main.pas", b"source")
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = {
            "format": 2,
            "library_option": {"name": "library", "type": "string", "default": "library.sqlite"},
            "commands": [{
                "name": "extract_deck",
                "arguments": [
                    {"name": "deck_name", "type": "string", "presence": "scu$required"},
                    {"name": "output_file", "type": "string", "presence": "scu$optional"},
                ],
                "options": [{"name": "revision", "type": "integer", "value": "REV"}],
                "default_values": {"output_file": "legacy copy"},
            }],
        }
        (self.root / "commands.json").write_text(json.dumps(definitions))
        self.run_scu("extract_deck", "main.pas", executable=executable)
        self.assertEqual((self.root / "legacy copy").read_bytes(), b"source")
        self.run_scu("extract_deck", error="Missing required argument deck_name", executable=executable)

    @contextmanager
    def terminal_session(self, *arguments, columns=None, rows=24, executable=SCU,
                         controlling=False, **environment):
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
                        self.assertTrue(select.select([master], [], [], 5)[0], output)
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
        names = "configure_library, configure, conl, modify_library"
        description = "Set library defaults, numbering increments, editor, or build command."
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
                if columns == 72:
                    indent = len(names) + 2
                    end = next(i for i, line in enumerate(listing) if line.startswith("create_deck,"))
                    first, *continuations = listing[:end]
                    self.assertTrue(continuations)
                    self.assertEqual(first[:indent], names + "  ")
                    self.assertTrue(all(line.startswith(" " * indent) for line in continuations))
                    self.assertEqual(" ".join(line[indent:] for line in listing[:end]), description)
                elif columns == 36:
                    start = next(i for i, line in enumerate(listing) if line.startswith("  "))
                    end = next(i for i, line in enumerate(listing) if line.startswith("create_deck,"))
                    self.assertEqual(" ".join(listing[:start]), names)
                    self.assertTrue(all(line.startswith("  ") for line in listing[start:end]))
                    self.assertEqual(" ".join(line[2:] for line in listing[start:end]), description)
                os.write(terminal, b"quit\n")
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
                start = lines.index("  --revision (r) : integer = scu$optional") + 1
                end = lines.index("  --version (v) : string = scu$optional")
                self.assertGreater(end - start, 1)
                self.assertTrue(all(line.startswith("    ") for line in lines[start:end]))
                self.assertEqual(" ".join(line[4:] for line in lines[start:end]),
                                 extract["options"][0]["description"])
                self.assertIn("  " + extract["examples"][0]["command"], lines)
                os.write(terminal, b"quit\n")
                self.assertEqual(process.wait(timeout=5), 0)

    def test_interactive_parameter_prompt_wraps_to_the_terminal_width(self):
        executable = self.root / "scu"
        shutil.copy2(SCU, executable)
        definitions = json.loads(SCU.with_name("commands.json").read_bytes())
        store = next(command for command in definitions["commands"] if command["name"] == "store_deck")
        description = "Use a source file from the working directory to create or revise the deck."
        store["arguments"][1]["description"] = "    " + description
        store["arguments"][1]["value"] = "input.txt"
        (self.root / "commands.json").write_text(json.dumps(definitions))
        (self.root / "input.txt").write_bytes(b"prompt source\n")

        with self.terminal_session(TERM="dumb", columns=30, executable=executable) as (
            process, terminal, read_until
        ):
            read_until(b"scu> ")
            os.write(terminal, b"store_deck sample\n")
            lines = read_until(b"source_file= ").decode().splitlines()
            self.assertTrue(all(len(line) <= 30 for line in lines), lines)
            body = [line for line in lines if line.startswith("    ")]
            self.assertGreater(len(body), 1)
            self.assertEqual(" ".join(line[4:] for line in body), description)
            self.assertIn("Press Enter to accept the default.", " ".join(lines))
            self.assertEqual(lines[-1], "source_file= ")
            os.write(terminal, b"\n")
            self.assertIn(b"sample version 1.0", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

        self.run_scu("extd", "sample", "result")
        self.assertEqual((self.root / "result").read_bytes(), b"prompt source\n")

    def test_display_library_runs_when_opening_an_existing_library_at_a_terminal(self):
        project = self.root / "project library.sqlite"
        self.run_scu(project, "init")
        self.run_scu(project, "lock_version")
        summary, header = self.run_scu(project, "disl").split("\n", 1)
        self.assertEqual(summary, f'Library "{project}", current version 1.0, previous locked version none.')
        self.assertEqual(json.loads(header)["editor"], ["vi"])
        self.assertEqual(json.loads(header)["build_command"], "")
        self.run_scu(project, "start_version", "1.1")
        editor = ["code", "--wait", "editor argument"]
        build_command = 'make -C "$1"'
        self.run_scu(project, "configure_library", "editor=" + json.dumps(editor),
                     "build_command=" + build_command, "comment_prefix=#", "version_increment=0.05")
        expected = f'Library "{project}", current version 1.1, previous locked version 1.0.'
        expected_header = json.loads(self.run_scu(project, "show_library"))
        self.assertEqual(expected_header["editor"], editor)
        self.assertEqual(expected_header["build_command"], build_command)
        summary, header = self.run_scu(project, "disl").split("\n", 1)
        self.assertEqual(summary, expected)
        self.assertEqual(json.loads(header), expected_header)

        with self.terminal_session(f"ln={project}") as (process, terminal, read_until):
            startup = read_until(b"scu> ").decode().replace("\r\n", "\n")
            self.assertIn(expected + "\n", startup)
            header = startup.split(expected + "\n", 1)[1].rsplit("scu> ", 1)[0]
            self.assertEqual(json.loads(header), expected_header)
            os.write(terminal, b"quit\n")
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
            os.write(terminal, b"init\n")
            self.assertIn(b"Initialized version 1.0", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_interrupt_cancels_pending_command_and_keeps_session_open(self):
        with self.terminal_session() as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"store_deck\n")
            self.assertIn(b"deck_name (deck, dn) : string = scu$required", read_until(b"deck_name= "))
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertIn("records=4", self.run_scu("verify_audit"))

    def test_review_interrupt_during_build_preserves_pending_changes(self):
        self.store("main", b"source")
        self.run_scu("conl", "bc=echo build-started; sleep 30")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            os.write(terminal, b"expd main built\n")
            read_until(b"build-started")
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Build command interrupted", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 1)
        self.assertIn("pending\t", self.run_scu("ddl"))
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

    def test_review_hangup_saves_and_termination_restores_terminal(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            process.send_signal(signal.SIGHUP)
            self.assertEqual(process.wait(timeout=5), 0)
            self.assertTrue(termios.tcgetattr(terminal)[3] & termios.ICANON)
        self.assertIn("pending\t", self.run_scu("ddl"))
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
                self.assertIn(f"{name}\t", self.run_scu("ddl"))
        self.assertIn("interrupted=0", self.run_scu("verify_audit"))

    def test_termination_recovers_pending_changes_when_library_lock_is_busy(self):
        lock_path = self.library.with_suffix(".sqlite.lock")
        with self.terminal_session(TERM="dumb") as (process, terminal, read_until), lock_path.open("rb") as lock:
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            fcntl.flock(lock, fcntl.LOCK_EX)
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        recovery, = self.root.glob("library.sqlite.recovery-*.json")
        document = json.loads(recovery.read_bytes())
        self.assertEqual([entry["deck"] for entry in document["revisions"]], ["pending"])
        self.assertEqual(recovery.stat().st_mode & 0o777, 0o600)
        self.assertNotIn("pending\t", self.run_scu("ddl"))

    def test_sigterm_during_build_saves_pending_changes(self):
        database = self.root / "project.sqlite"
        self.run_scu(database, "init")
        self.run_scu(database, "cred", "main")
        self.run_scu(database, "conl", "bc=echo build-started; exec sleep 30")
        with self.terminal_session(database, TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            os.write(terminal, b"expd main built\n")
            read_until(b"build-started")
            process.send_signal(signal.SIGTERM)
            self.assertEqual(process.wait(timeout=5), 128 + signal.SIGTERM)
        self.assertIn("pending\t", self.run_scu(database, "ddl"))
        self.assertIn("interrupted=0", self.run_scu(database, "verify_audit_trail"))

    def test_build_uses_the_controlling_terminal_and_returns_it_to_scu(self):
        self.store("main", b"source")
        self.run_scu("conl", 'bc=stty tostop </dev/tty || exit; printf "Build answer? "; '
                     'read answer </dev/tty; echo "got=$answer"')
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"expd main output\n")
            read_until(b"Build answer? ")
            os.write(terminal, b"yes\n")
            self.assertIn(b"got=yes", read_until(b"scu> "))
            self.assertFalse(termios.tcgetattr(terminal)[3] & termios.TOSTOP)
            os.write(terminal, b"expd main output\n")
            read_until(b"Build answer? ")
            os.write(terminal, b"\x03")
            self.assertIn(b"Build command interrupted", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 1)
        events = [json.loads(line.split(b" ", 1)[1]) for line in self.audit_lines()]
        self.assertEqual([event["success"] for event in events if event["phase"] == "build"], [True, False])

    def test_stopped_build_returns_control_to_scu(self):
        self.store("main", b"source")
        self.run_scu("conl", "bc=kill -STOP $$")
        with self.terminal_session(TERM="dumb", controlling=True) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"expd main output\n")
            self.assertIn(b"Build command stopped before it finished", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 1)

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
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.run_scu("extd", "main", "saved")
        self.assertEqual((self.root / "saved").read_bytes(), b"original\nedited\n")

    def test_review_hangup_conflict_writes_a_recovery_library(self):
        path = self.root / "project.sqlite"
        source = self.root / "pending-source"
        source.write_bytes(b"pending source\r\n\xff")
        self.run_scu(path, "init")
        self.run_scu(path, "cred", "base")
        with self.terminal_session(path, TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"cred pending from_file=pending-source\n")
            read_until(b"scu> ")
            self.run_scu(path, "cred", "concurrent")
            process.send_signal(signal.SIGHUP)
            self.assertEqual(process.wait(timeout=5), 1)
        recovery, = self.root.glob("project.sqlite.recovery-*.json")
        document = json.loads(recovery.read_bytes())
        self.assertEqual([entry["deck"] for entry in document["revisions"]], ["base", "pending"])
        self.assertEqual(recovery.stat().st_mode & 0o777, 0o600)
        self.assertIn("concurrent\t", self.run_scu(path, "ddl"))
        self.run_scu(path, "recover_library", recovery, error="destination already exists")
        restored = self.root / "restored.sqlite"
        self.assertIn("Restored 2 revision(s)", self.run_scu(restored, "recl", recovery))
        self.assertEqual(restored.stat().st_mode & 0o777, 0o600)
        self.assertIn("records=2 interrupted=0", self.run_scu(restored, "verify_audit_trail"))
        history = self.run_scu(restored, "show_history")
        self.assertIn("recover_library recovery_file=", history)
        self.assertEqual(self.run_scu(restored, "ddl"), "base\t1.0-0.000\npending\t1.0-0.000")
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
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            for command in (b"lock_version", b"start_version 1.1", b"store_deck main pending-source"):
                os.write(terminal, command + b"\n")
                self.assertNotIn(b"scu: ", read_until(b"scu> "))
            self.library.rename(base)
            process.send_signal(signal.SIGHUP)
            self.assertEqual(process.wait(timeout=5), 1)
        recovery, = self.root.glob("library.sqlite.recovery-*.json")
        document = json.loads(recovery.read_bytes())
        self.assertEqual(document["format"], "scu-pending-recovery-v1")
        self.assertEqual(document["base_library_revision"], 1)
        self.assertEqual(recovery.stat().st_mode & 0o777, 0o600)
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
        self.assertEqual(self.run_scu(base, "ddl"), "main\t1.0-0.000")

        # Older pending-only files did not record the base identity and generation.
        del document["base_library_state"]
        legacy = self.root / "legacy-recovery.json"
        legacy.write_text(json.dumps(document))
        restored_legacy = self.root / "legacy.sqlite"
        self.run_scu(restored_legacy, "recover_library", legacy, f"base_library={base}")
        self.assertIn("records=2 interrupted=0", self.run_scu(restored_legacy, "verify_audit_trail"))

    def test_pending_recovery_without_saved_revisions_needs_no_base(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"create_deck pending\n")
            self.assertIn(b"pending version", read_until(b"scu> "))
            self.library.unlink()
            process.send_signal(signal.SIGHUP)
            self.assertEqual(process.wait(timeout=5), 1)
        recovery, = self.root.glob("library.sqlite.recovery-*.json")
        self.assertEqual(json.loads(recovery.read_bytes())["base_library_revision"], 0)
        self.run_scu("recover_library", recovery)
        self.assertIn("records=2 interrupted=0", self.run_scu("verify_audit_trail"))
        self.assertEqual(self.run_scu("ddl"), "pending\t1.0-0.000")

    def test_terminal_editor_handles_utf8_keys_and_ctrl_c_and_restores_terminal(self):
        (self.root / "café").write_bytes(b"source")
        with self.terminal_session(TERM="xterm", LC_ALL="C.UTF-8") as (process, terminal, read_until):
            read_until(b"scu> ")
            cooked_flags = termios.ICANON | termios.ECHO | termios.ISIG
            self.assertEqual(termios.tcgetattr(terminal)[3] & cooked_flags, 0)

            os.write(terminal, "Xstore_deck sample cafe界".encode() + b"\x1b[D\x7f" +
                     "é".encode() + b"\x1b[C\x7f\x1b[H\x1b[3~\x1b[F\r")
            self.assertIn(b"sample version 1.0 revision 0.000", read_until(b"scu> "))

            os.write(terminal, b"store_deck cancelled\n")
            read_until(b"source_file= ")
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
                         ["store_deck sample café", "store_deck cancelled"])
        with self.terminal_session(TERM="xterm", LC_ALL="C.UTF-8") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"\x1b[A\x1b[A\n")
            self.assertIn(b"No changes to sample", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_history_recalls_and_edits_commands(self):
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"display_command cn=init\n")
            self.assertIn(b"initialize_library, inil, init", read_until(b"scu> "))
            os.write(terminal, b"\x1b[A\x7f\x7f\x7f\x7fquit\n")
            self.assertIn(b"quit_session, q, quis, quit", read_until(b"scu> "))
            os.write(terminal, b"display_command cn=quit")
            os.write(terminal, b"\x1b[A\x1b[A\x1b[B\x1b[B\n")
            self.assertIn(b"quit_session, q, quis, quit", read_until(b"scu> "))
            os.write(terminal, b"unfinished")
            read_until(b"unfinished")
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b"store_deck\n")
            read_until(b"deck_name= ")
            process.send_signal(signal.SIGINT)
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_reverse_search_recalls_saved_history_for_editing(self):
        saved = ["display_command cn=quit", "display_command_list", "display_command cn=init"]
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            for command in saved:
                os.write(terminal, command.encode() + b"\n")
                read_until(b"scu> ")
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

        history = self.root / "state/scu/history.json"
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"\x12cn=")
            read_until(b"cn= => display_command cn=init")
            os.write(terminal, b"\x12")
            read_until(b"cn= => display_command cn=quit")
            os.write(terminal, b"\n")
            read_until(b"scu> display_command cn=quit")
            self.assertEqual(json.loads(history.read_bytes()), saved)
            os.write(terminal, b"\x7f" * 4 + b"extd\n")
            self.assertIn(b"extract_deck, extd", read_until(b"scu> "))

            os.write(terminal, b"display_command cn=quit\x12initx")
            read_until(b"initx => (no match)")
            os.write(terminal, b"\x7f")
            read_until(b"init => display_command cn=init")
            os.write(terminal, b"\x1b")
            read_until(b"scu> display_command cn=quit")
            os.write(terminal, b"\n")
            self.assertIn(b"quit_session, q, quis, quit", read_until(b"scu> "))

            os.write(terminal, b"partial\x12cn=\x03")
            self.assertIn(b"Command cancelled.", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

        self.assertEqual(json.loads(history.read_bytes()),
                         saved + ["display_command cn=extd", "display_command cn=quit"])

    def test_terminal_history_survives_restart_and_merges_overlapping_sessions(self):
        environment = {
            "TERM": "xterm", "XDG_STATE_HOME": "",
            "HOME": str(self.root / "home"),
        }
        (self.root / "prompt answer").write_bytes(b"source")
        history = self.root / "home" / ".local" / "state" / "scu" / "history.json"
        with self.terminal_session(**environment) as (first, terminal, read_until), \
             self.terminal_session(**environment) as (second, other_terminal, other_read_until):
            self.assertNotIn(b"Could not load command history", read_until(b"scu> "))
            self.assertNotIn(b"Could not load command history", other_read_until(b"scu> "))
            os.write(terminal, b"store_deck remembered\n")
            read_until(b"source_file= ")
            os.write(terminal, b"prompt answer\n")
            self.assertIn(b"remembered version 1.0 revision 0.000", read_until(b"scu> "))
            os.write(other_terminal, b"display_command cn=quit\n")
            self.assertIn(b"quit_session, q, quis, quit", other_read_until(b"scu> "))
            self.assertEqual(json.loads(history.read_bytes()),
                             ["store_deck remembered", "display_command cn=quit"])
            self.assertEqual(history.stat().st_mode & 0o777, 0o600)
            os.write(terminal, b"quit\n")
            os.write(other_terminal, b"q\n")
            self.assertEqual(first.wait(timeout=5), 0)
            self.assertEqual(second.wait(timeout=5), 0)

        with self.terminal_session(**environment) as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"\x1b[A\x7f\x7f\x7f\x7finit\n")
            self.assertIn(b"initialize_library, inil, init", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)
        self.assertEqual(json.loads(history.read_bytes()),
                         ["store_deck remembered", "display_command cn=quit", "display_command cn=init"])

    def test_terminal_tab_completes_command_and_parameter_names_and_aliases(self):
        (self.root / "source file").write_bytes(b"source")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"display_\t\t")
            matches = read_until(b"scu> display_")
            self.assertIn(b"display_command_list", matches)
            self.assertIn(b"display_deck_list", matches)
            os.write(terminal, b"\x15")
            os.write(terminal, b'store_de\tdeck_na\tmain.pas s\t"source file"\n')
            self.assertIn(b"main.pas version 1.0 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"extd\tdn\tmain.pas output_f\tcopy --rev\t1\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "copy").read_bytes(), b"source")
            os.write(terminal, b"extd\tdn=main.pas o\tsecond rev\t1\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "second").read_bytes(), b"source")
            os.write(terminal, b"ddl\t--r\t1\n")
            self.assertIn(b"main.pas\t1.0-0.000", read_until(b"scu> "))
            os.write(terminal, b"q\t\n")
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
                os.write(terminal, b"extd o=pick-\t\t")
                output = read_until(b"scu> extd o=pick-").decode()
                rows = output.split("\r\n")[1:-1]
                self.assertEqual({candidate for row in rows for candidate in row.split()},
                                 {"o=" + name for name in names})
                for row in rows:
                    self.assertLessEqual(cells(row), columns)
                    self.assertEqual(len(row.split()), per_row)
                    if per_row == 2:
                        second = row.split()[1]
                        self.assertEqual(cells(row[:row.index(second)]), 12)
                os.write(terminal, b"a\n")
                read_until(b"scu> ")
                self.assertEqual((self.root / "pick-a").read_bytes(), b"source")

                if columns == 20:
                    os.write(terminal, b"extd o=long-\t\t")
                    output = read_until(b"scu> extd o=long-").decode()
                    rows = output.split("\r\n")[1:-1]
                    labels = ["o=" + name for name in long_names]
                    self.assertEqual(rows, [part for label in labels for part in (label[:20], label[20:])])
                    os.write(terminal, b"\x15")

                os.write(terminal, b"quit\n")
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
            os.write(terminal, b"\x15extd o=my\t\t")
            matches = read_until(b"scu> extd o=my\\ fi")
            self.assertIn(b"o=my\\ file.txt", matches)
            self.assertIn(b"o=my\\ fine.txt", matches)
            os.write(terminal, b"\x15extd o=back\t\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "back\\slash.txt").read_bytes(), b"source")
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_completion_pages_and_restores_the_draft_cursor(self):
        self.store("main", b"source")
        names = [f"pick-{index:02}" for index in range(20)]
        for name in names:
            (self.root / name).touch()
        prefix, tail = b"extd o=pick-", b" dn=main"
        complete = prefix + tail + b"\x02" * len(tail) + b"\t\t"
        draft = b"scu> " + prefix + tail

        def matches(output):
            return [label.decode()[2:] for label in re.findall(rb"o=pick-\d{2}", output)]

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
            os.write(terminal, b"19\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "pick-19").read_bytes(), b"source")
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_completes_library_values_and_paths(self):
        self.store("main.pas", b"old\n")
        self.run_scu("lock_version")
        self.run_scu("start_version", "2.0")
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
            os.write(terminal, b"ddl r=1\t\t")
            self.assertIn(b"r=10", read_until(b"scu> ddl r=1"))
            self.assertEqual(self.audit_lines(), audit_before)
            os.write(terminal, b"\x15extd ma\t o=out\twork\t --r 1\n")
            read_until(b"scu> ")
            self.assertEqual((directory / "working copy").read_bytes(), b"old\n")
            os.write(terminal, b"expd dn=ma\t v=2.\t o=expanded\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "expanded").read_bytes(), b"new\n")
            os.write(terminal, b"difd ma\t 1.\t 2.0-0.008\t\n")
            self.assertIn(b"+++ main.pas@2.0-0.008", read_until(b"scu> "))
            os.write(terminal, b"difd ma\t 1.\t scu$cur\t\n")
            self.assertIn(b"+++ main.pas@2.0-0.008", read_until(b"scu> "))
            os.write(terminal, b"difd ma\t 1.\t\n")
            self.assertIn(b"+++ main.pas@2.0-0.008", read_until(b"scu> "))
            os.write(terminal, b"difd ma\t scu$pre\t\n")
            self.assertIn(b"From deck version 2.0-0.007.", read_until(b"scu> "))
            os.write(terminal, b"difd ma\t\n")
            self.assertIn(b"From deck version 2.0-0.007.", read_until(b"scu> "))
            os.write(terminal, b"store_deck prompted\n")
            read_until(b"source_file= ")
            os.write(terminal, b"prompt c\t\n")
            self.assertIn(b"prompted version 2.0 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"extd prompted\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "prompted").read_bytes(), b"prompt source\n")
            os.write(terminal, b'cred latest ff="source f\t\n')
            self.assertIn(b"latest version 2.0 revision 0.000", read_until(b"scu> "))
            os.write(terminal, b"difd latest scu$\t\n")
            self.assertIn(b"From deck version 2.0-0.000.", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_filters_decks_by_snapshot_and_revisions_by_deck(self):
        self.store("alpha-old", b"old\n")
        self.store("inherited", b"inherited\n")
        self.run_scu("lock_version")
        self.run_scu("start_version", "2.0")
        self.store("alpha-new", b"new deck\n")
        for index in range(6):
            self.store("other", f"other {index}\n".encode())
        self.store("alpha-old", b"updated\n")
        self.store("alpha-new", b"updated new deck\n")

        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            for command, output, source in (
                (b"extd --v 1.0 dn=alpha-\t o=old-version\n", "old-version", b"old\n"),
                (b"extd v=2.0 inh\t o=inherited-copy\n", "inherited-copy", b"inherited\n"),
                (b"extd r=1 dn=alpha-\t o=old-revision\n", "old-revision", b"old\n"),
            ):
                os.write(terminal, command)
                read_until(b"scu> ")
                self.assertEqual((self.root / output).read_bytes(), source)

            tail = b" o=version-after v=1.0"
            os.write(terminal, b"extd dn=alpha-" + tail + b"\x02" * len(tail) + b"\t\x05\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "version-after").read_bytes(), b"old\n")

            os.write(terminal, b"difd fs=2.0-0.000 ts=1.0-0.000 dn=alpha-\t\n")
            self.assertIn(b"+++ alpha-old@1.0-0.000", read_until(b"scu> "))

            os.write(terminal, b"extd ALPHA-OLD r=1\t\t")
            revisions = read_until(b"scu> extd ALPHA-OLD r=1")
            self.assertIn(b"r=10", revisions)
            self.assertNotIn(b"r=11", revisions)
            os.write(terminal, b"\x15difd dn=alpha-old ts=1.0-0.000 fs=2.0-\t\n")
            self.assertIn(b"--- alpha-old@2.0-0.000", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_filters_versions_to_snapshots_containing_the_deck(self):
        self.store("earlier", b"old")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.1")
        self.store("later", b"source")
        self.run_scu("lock_version")
        self.run_scu("start_version", "1.2")

        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            os.write(terminal, b"ddl v=1.\t\t")
            self.assertIn(b"v=1.0", read_until(b"scu> ddl v=1."))

            os.write(terminal, b"\x15extd dn=LATER v=1.\t\t")
            matches = read_until(b"scu> extd dn=LATER v=1.")
            self.assertNotIn(b"v=1.0", matches)
            self.assertIn(b"v=1.1", matches)
            self.assertIn(b"v=1.2", matches)
            os.write(terminal, b"2 o=inherited-copy\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "inherited-copy").read_bytes(), b"source")

            os.write(terminal, b"difd dn=later ts=scu$current_deck_version fs=1.\t\n")
            self.assertIn(b"From deck version 1.1-0.000.", read_until(b"scu> "))
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_skips_supplied_parameters_and_all_their_aliases(self):
        self.store("main.pas", b"source")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            command = b"expd main.pas o=copy --r 1 "
            os.write(terminal, command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"comment-prefix", matches)
            self.assertNotRegex(
                matches,
                rb"(?:^|\s)(?:deck_name|deck|dn|output_file|output|o|revision|r|version|v)(?:\s|$)",
            )

            command = b"expd dn=main.pas o=copy r=1 --"
            os.write(terminal, b"\x15" + command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"--comment-prefix", matches)
            self.assertNotRegex(matches, rb"(?:^|\s)--(?:revision|r|version|v)(?:\s|$)")

            prefix = b"expd main.pas build=no --"
            tail = b" --r 1 o=copy"
            os.write(terminal, b"\x15" + prefix + tail + b"\x02" * len(tail) + b"\t\t\t")
            matches = read_until(b"scu> " + prefix + b"c" + tail)
            self.assertIn(b"--comment-prefix", matches)
            self.assertNotIn(b"--revision", matches)
            self.assertNotIn(b"--version", matches)

            os.write(terminal, b"\x05\x15expd dn=main.pas o=expanded r=1 cp\t//\n")
            read_until(b"scu> ")
            self.assertEqual((self.root / "expanded").read_bytes(), b"source")
            os.write(terminal, b"quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_terminal_tab_skips_revision_when_version_is_selected(self):
        self.store("main.pas", b"source")
        self.run_scu("expd", "main.pas", "unused", "v=1.0", "r=1",
                     error="Choose either --version or --revision.")
        with self.terminal_session(TERM="xterm") as (process, terminal, read_until):
            read_until(b"scu> ")
            command = b"expd main.pas o=copy --"
            os.write(terminal, command + b"\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"--version", matches)
            self.assertIn(b"--revision", matches)

            command = b"expd main.pas o=copy --v 1.0 "
            os.write(terminal, b"\x15" + command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"comment-prefix", matches)
            self.assertNotRegex(matches, rb"(?:^|\s)(?:revision|r)(?:\s|$)")

            command = b"expd main.pas o=copy v=1.0 --"
            os.write(terminal, b"\x15" + command + b"\t\t\t")
            matches = read_until(b"scu> " + command)
            self.assertIn(b"--comment-prefix", matches)
            self.assertNotRegex(matches, rb"(?:^|\s)--(?:revision|r)(?:\s|$)")
            os.write(terminal, b"\x15quit\n")
            self.assertEqual(process.wait(timeout=5), 0)

    def test_concurrent_stores_preserve_all_revisions(self):
        source = self.root / "input"
        source.write_bytes(b"same bytes")

        with concurrent.futures.ThreadPoolExecutor(max_workers=4) as workers:
            list(workers.map(
                lambda number: self.run_scu("store_deck", f"deck{number}", source), range(8)
            ))
        self.assertEqual(len(self.run_scu("ddl").splitlines()), 8)
        self.assertIn("records=20 interrupted=0", self.run_scu("verify_audit"))
        self.assertEqual(len(self.read_library()["revisions"]), 8)


if __name__ == "__main__":
    unittest.main()
