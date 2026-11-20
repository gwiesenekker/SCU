"""Import numbered source directories through SCU's audited command interface.

Import only new or modified decks, ignoring an initial // SCU REVISION line
when comparing source bytes. Stored revisions retain their original bytes.
"""

import argparse
from collections import Counter, defaultdict
from dataclasses import dataclass
from decimal import Decimal
import hashlib
import json
import math
import os
from pathlib import Path
import re
import shutil
import subprocess
import sys
import tempfile

VERSION = re.compile(r"(0|[1-9][0-9]*)\.[0-9]{1,10}\Z")
DECK = re.compile(r"[A-Za-z0-9][A-Za-z0-9_.-]{0,127}\Z")
HEADINGS = re.compile(r"^Revision:[ \t]*([^\r\n]*)", re.MULTILINE)
MANIFEST = "scu-import-manifest.json"
MAX_SOURCE = 64 * 1024 * 1024
REVISION_LINE = re.compile(rb"\A// SCU REVISION(?=[ \t\r\n]|\Z)[^\r\n]*(?:\r\n|\r|\n|\Z)")
COMPARISON = "bytes_ignoring_initial_scu_revision_line"


class ImportFailure(Exception):
    pass


@dataclass(frozen=True)
class SourceFile:
    path: Path
    relative: str
    size: int
    modified_ns: int


@dataclass(frozen=True)
class Snapshot:
    version: str
    files: tuple
    history: tuple
    description: str
    missing_description: bool


def read_history(path, encoding):
    text = path.read_text(encoding=encoding)
    matches = list(HEADINGS.finditer(text))
    entries = defaultdict(list)
    for index, match in enumerate(matches):
        heading = match.group(1).strip()
        version = heading.split(maxsplit=1)[0] if heading else ""
        if not VERSION.fullmatch(version):
            raise ImportFailure(f"{path}: invalid revision heading {heading!r}")
        end = matches[index + 1].start() if index + 1 < len(matches) else len(text)
        body = text[match.end():end]
        description = re.search(r"^Description:[ \t]?(.*)", body, re.MULTILINE)
        if description is None or not body[description.start(1):].strip():
            raise ImportFailure(f"{path}: revision {version} has no description")
        date = re.search(r"^Date:[ \t]*(.*)", body, re.MULTILINE)
        entries[version].append({
            "heading": heading,
            "date": date.group(1) if date else "",
            "description": body[description.start(1):].strip("\n"),
        })
    return entries


def source_files(directory):
    result = []

    def visit(parent):
        for path in sorted(parent.iterdir()):
            # Filter before inspection and traversal, including hidden symlinks.
            if path.name.startswith("."):
                continue
            if path.is_symlink():
                raise ImportFailure(f"Symbolic links inside version directories are not supported: {path}")
            if path.is_dir():
                visit(path)
                continue
            if not path.is_file():
                raise ImportFailure(f"Not a regular source file: {path}")
            info = path.stat()
            if info.st_size > MAX_SOURCE:
                raise ImportFailure(f"Source file exceeds SCU's 64 MiB limit: {path}")
            result.append(SourceFile(path, path.relative_to(directory).as_posix(),
                                     info.st_size, info.st_mtime_ns))

    visit(directory)
    return tuple(sorted(result, key=lambda file: file.relative))


def plan_import(archive, encoding, strict_history):
    history = read_history(archive / "HISTORY", encoding)
    directories = []
    numbers = set()
    for directory in archive.iterdir():
        if not directory.is_dir() or not VERSION.fullmatch(directory.name):
            continue
        if directory.is_symlink():
            raise ImportFailure(f"Symbolic version directory is not supported: {directory}")
        if int(directory.name.split(".")[0]) > 2147483647:
            raise ImportFailure(f"Version is outside SCU's supported range: {directory.name}")
        number = Decimal(directory.name)
        if number in numbers:
            raise ImportFailure(f"Duplicate numeric version: {directory.name}")
        numbers.add(number)
        directories.append(directory)
    if not directories:
        raise ImportFailure(f"No MAJOR.MINOR version directories found in {archive}")
    snapshots = []
    for directory in sorted(directories, key=lambda path: Decimal(path.name)):
        records = tuple(history.get(directory.name, ()))
        missing = not records
        if missing and strict_history:
            raise ImportFailure(f"No HISTORY description found for version {directory.name}")
        description = "\n\n".join(record["description"] for record in records)
        if missing:
            description = f"No HISTORY description found for version {directory.name}."
        if len(description.encode("utf-8")) > 64 * 1024 or "\0" in description:
            raise ImportFailure(f"Version {directory.name}: description exceeds 64 KiB or contains NUL")
        snapshots.append(Snapshot(directory.name, source_files(directory), records, description, missing))
    return snapshots


def deck_names(snapshots):
    paths = sorted({file.relative for snapshot in snapshots for file in snapshot.files})
    folded = Counter(path.lower() for path in paths)
    names = {}
    used = {MANIFEST}
    # Reserve plain names first so an encoded path cannot steal a real filename.
    for path in paths:
        if DECK.fullmatch(path) and folded[path.lower()] == 1 and path.lower() != MANIFEST:
            names[path] = path.lower()
            used.add(path.lower())
    for path in paths:
        if path in names:
            continue
        name = "import-file-" + hashlib.sha256(path.encode("utf-8")).hexdigest()
        if name in used:
            raise ImportFailure(f"Encoded deck-name collision for {path!r}")
        names[path] = name
        used.add(name)
    return names


def scu_quote(value):
    if any(character in value for character in "\r\n\0"):
        raise ImportFailure("A generated batch argument contains a newline or NUL")
    return '"' + value.replace("\\", "\\\\").replace('"', '\\"') + '"'


class Runner:
    def __init__(self, executable, library, timeout):
        self.executable = executable
        self.library = library
        self.timeout = timeout

    def run(self, *arguments, batch=None):
        result = subprocess.run(
            [str(self.executable), "ln=" + str(self.library), *arguments],
            input=batch if batch is not None else "", text=True, encoding="utf-8",
            capture_output=True, timeout=self.timeout,
        )
        if result.returncode:
            detail = (result.stderr + result.stdout)[-8000:]
            raise ImportFailure(f"SCU failed ({result.returncode}):\n{detail}")
        return result.stdout.strip()


def comparison_bytes(data):
    """Ignore just an initial revision header, not other text or body whitespace."""
    header = REVISION_LINE.match(data)
    return data[header.end():] if header else data


def stage_files(snapshot, names, inputs, previous_files):
    rows = []
    commands = []
    current_files = {}
    for index, file in enumerate(snapshot.files):
        before = file.path.stat()
        if (before.st_size, before.st_mtime_ns) != (file.size, file.modified_ns):
            raise ImportFailure(f"Source changed during import: {file.path}")
        data = file.path.read_bytes()
        after = file.path.stat()
        if len(data) != file.size or after.st_mtime_ns != file.modified_ns:
            raise ImportFailure(f"Source changed while reading: {file.path}")
        deck = names[file.relative]
        # Preserve an actual root filename as the deck's source association.
        # Flattened subdirectories and reserved manifest names use their mapped ID.
        filename = file.relative if "/" not in file.relative and "\\" not in file.relative and file.relative != MANIFEST else deck
        source = inputs / filename
        source.write_bytes(data)
        current_files[deck] = source
        rows.append({"path": file.relative, "deck_name": deck,
                     "size": len(data), "sha1": hashlib.sha1(data).hexdigest()})
        previous = previous_files.get(deck)
        # Compare bodies independently of revision stamps on either side.
        # Do not strip headers from staged/stored bytes or archive checksums.
        if previous is None or comparison_bytes(previous.read_bytes()) != comparison_bytes(data):
            commands.append(f"import_deck deck_name={scu_quote(deck)} source_file={scu_quote(source.name)}")
    return rows, commands, current_files


def require_new_destination(output):
    for path in (output, *(Path(str(output) + suffix) for suffix in ("-wal", "-shm", "-journal", ".lock"))):
        if os.path.lexists(path):
            raise ImportFailure(f"Destination already exists: {path}")


def import_snapshots(snapshots, names, archive, output, executable, prefix, timeout):
    with tempfile.TemporaryDirectory(prefix=".scu-import-", dir=output.parent) as temporary:
        staging = Path(temporary)
        library = staging / ".scu-archive.sqlite"
        inputs = staging
        runner = Runner(executable, library, timeout)
        runner.run("initialize_library", "version=" + snapshots[0].version)
        runner.run("configure_library", "comment_prefix=" + prefix)
        previous_files = {}
        previous_directory = staging / "previous-inputs"
        for index, snapshot in enumerate(snapshots):
            rows, commands, current_files = stage_files(snapshot, names, inputs, previous_files)
            stored_count = len(commands)
            current = {row["deck_name"] for row in rows}
            removed = sorted(previous_files.keys() - current)
            commands[:0] = [f"delete_deck deck_name={scu_quote(deck)}" for deck in removed]
            if index:
                commands.insert(0, "create_version version=" + snapshot.version)
            manifest = inputs / MANIFEST
            manifest.write_text(json.dumps({
                "format": 1, "source_archive": str(archive), "version": snapshot.version,
                "comparison": COMPARISON,
                "history": snapshot.history, "missing_history_description": snapshot.missing_description,
                "files": rows,
            }, ensure_ascii=False, indent=2) + "\n", encoding="utf-8")
            commands.append(f"import_deck deck_name={MANIFEST} source_file={scu_quote(manifest.name)}")
            commands.append("save_library")
            runner.run(batch="\n".join(commands) + "\n")
            # Pass multiline text as one argv value, not as lines of a batch file.
            runner.run("lock_version", "description=" + snapshot.description)
            print(f"Imported {snapshot.version}: {len(rows)} files, {len(removed)} deletions, "
                  f"{stored_count} stored, {len(rows) - stored_count} inherited", flush=True)
            # Keep an immutable, unmodified copy of the preceding archive snapshot.
            if previous_directory.exists():
                shutil.rmtree(previous_directory)
            previous_directory.mkdir()
            for source in current_files.values():
                source.rename(previous_directory / source.name)
            previous_files = {deck: previous_directory / file.name for deck, file in current_files.items()}
        verification = runner.run("verify_audit")
        # A hard link publishes a completed database atomically and never overwrites a target.
        require_new_destination(output)
        os.link(library, output)
        descriptor = os.open(output.parent, os.O_RDONLY | os.O_DIRECTORY)
        try:
            os.fsync(descriptor)
        finally:
            os.close(descriptor)
    print(f"Created {output}\nAudit verified: {verification}")


def main():
    parser = argparse.ArgumentParser(description=__doc__)
    parser.add_argument("archive", type=Path, help="SCU directory containing versions and HISTORY")
    parser.add_argument("library", type=Path, help="New .sqlite library to create (extension added if omitted; must not exist)")
    parser.add_argument("--scu", type=Path, default=Path(__file__).resolve().parents[1] / "build/scu")
    parser.add_argument("--dry-run", action="store_true", help="Validate and list the import without writing")
    parser.add_argument("--strict-history", action="store_true", help="Reject missing HISTORY entries")
    parser.add_argument("--encoding", default="utf-8", help="HISTORY and .COMMENT encoding (default: utf-8)")
    parser.add_argument("--comment-prefix", help="Override .COMMENT (otherwise // when absent)")
    parser.add_argument("--timeout", type=float, default=120, help="Seconds per SCU invocation (default: 120)")
    args = parser.parse_args()
    try:
        archive = args.archive.resolve(strict=True)
        output = args.library.absolute()
        extension = output.name[output.name.rfind("."):] if "." in output.name else ""
        if not extension:
            output = output.with_name(output.name + ".sqlite")
        elif extension.lower() != ".sqlite":
            raise ImportFailure("Library filename must have the .sqlite extension")
        require_new_destination(output)
        if not output.parent.is_dir():
            raise ImportFailure(f"Destination directory does not exist: {output.parent}")
        if output.is_relative_to(archive) or output.parent.resolve().is_relative_to(archive):
            raise ImportFailure("Put the destination outside the source archive")
        if not math.isfinite(args.timeout) or args.timeout <= 0:
            raise ImportFailure("--timeout must be finite and positive")
        prefix = args.comment_prefix
        if prefix is None:
            prefix = (archive / ".COMMENT").read_text(encoding=args.encoding).strip() if (archive / ".COMMENT").exists() else "//"
        if not prefix or len(prefix.encode("utf-8")) > 16 or prefix.strip() != prefix or any(ord(c) < 32 for c in prefix):
            raise ImportFailure("Expected a printable comment prefix of 1 to 16 bytes")
        snapshots = plan_import(archive, args.encoding, args.strict_history)
        names = deck_names(snapshots)
        previous = set()
        for snapshot in snapshots:
            current = {file.relative for file in snapshot.files}
            notice = " [missing HISTORY description]" if snapshot.missing_description else ""
            print(f"Plan {snapshot.version}: {len(current)} files, {len(previous - current)} deletions{notice}")
            previous = current
        print(f"{len(snapshots)} versions; {sum(len(s.files) for s in snapshots)} file snapshots; "
              f"{sum(name != path for path, name in names.items())} filename mappings")
        if not args.dry_run:
            executable = args.scu.resolve(strict=True)
            import_snapshots(snapshots, names, archive, output, executable, prefix, args.timeout)
    except (ImportFailure, OSError, UnicodeError, LookupError, subprocess.TimeoutExpired) as error:
        print(f"Import failed: {error}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("Import cancelled.", file=sys.stderr)
        return 130
    return 0


if __name__ == "__main__":
    sys.exit(main())
