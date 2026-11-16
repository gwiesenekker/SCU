# Source Code Utility

Source Code Utility (SCU) is a Free Pascal revision control tool inspired by
Control Data's NOS/VE SCU. A library holds named source decks. You can retrieve
the original bytes for editing and building, then publish a complete release
with version and modification-time macros expanded.

## Build

SCU currently targets Linux. It uses Free Pascal 3.2.2 with the FCL, hash,
and SQLite units, the zstd and SQLite development libraries, and the OpenSSL 3
runtime (`libcrypto.so.3`). On Debian-based systems, install
`make fpc fp-units-db fp-units-fcl fp-units-misc libsqlite3-dev libzstd-dev libssl3t64`.
The OpenSSL runtime package is called `libssl3` on some releases.

```sh
make
export PATH="$PWD/build:$PATH"
scu help
make test
```

The integration tests use Python 3 with SQLite JSON functions. Keep
`commands.json` beside the executable when copying it elsewhere. SCU reads
it at startup for command names, ordered arguments, aliases, and
help text.

## Platform layer

The clock and path services now have separate Linux and Windows backends behind
`ScuPlatformClock` and `ScuPlatformPaths`. `ScuClock` retains the existing UTC
millisecond timestamp format. Linux retains `gettimeofday`, `realpath`,
`/proc/self/exe` for CLI catalog discovery, the GUI's invocation-based sibling
lookup, XDG history/preferences locations, and case-sensitive native filename
bytes. Canonical file paths resolve the parent directory without following the
final filename, preserving existing atomic-replacement behavior.

The Windows backends use UTC FILETIME and wide-character APIs for executable,
absolute and canonical directory paths. Their path interface accepts and returns
UTF-8, understands both separators and compares resolved storage paths without
case sensitivity. Windows history and preferences locations use `LOCALAPPDATA`,
falling back to `APPDATA`; the GUI locates its sibling CLI as `scu.exe`.
Choosing a state/configuration path does not create directories.

`ScuFiles` is now the public file-service facade, selecting
`ScuPlatformFilesLinux` or `ScuPlatformFilesWindows`. Linux retains the existing
nonblocking regular-file reads, no-follow checks, `mkstemp`/`mkdtemp`, temporary
file locks, `rename`/no-replace hard links, permission/group preservation and
file/parent-directory `fsync` behavior.

The Windows file backend uses wide-character APIs (including extended paths),
checks opened handles for regular files and reparse points, and keeps binary
source bytes unchanged. Atomic writes create a unique file in the destination
directory, flush it with `FlushFileBuffers`, then use a write-through
[`MoveFileExW`](https://learn.microsoft.com/en-us/windows/win32/api/winbase/nf-winbase-movefileexw)
rename. No-replace writes never overwrite an existing destination, and failed
writes remove their temporary file without deleting the destination. Sharing or
access failures receive a short bounded retry and a contextual error. Open
readers may prevent replacement on Windows, even with delete sharing; close the
reader and retry rather than expecting Linux open-file replacement semantics.

Windows control files and temporary directories have protected access rules for
the current user and SYSTEM. Source outputs inherit directory permissions when
new and retain an existing regular file's DACL and inheritance protection when
replaced. Windows temporary files use a reserved byte-range cleanup lock beyond
the source data, kept open across the rename. Stale-file cleanup checks ownership,
refuses reparse points, leaves active files and unmarked stages alone, and never
recurses into unknown stage children. The future Windows library-lock backend
must lock byte zero of stage `.owner` sidecars to use the same cleanup protocol.

Windows has no supported directory `fsync` equivalent: `SyncParent` validates the
parent, while atomic writes use file flushing and write-through rename. These
operations do not promise identical power-loss durability to Linux on every
filesystem. Native Windows filesystem and crash testing remain necessary.

The application still targets Linux. Library/output locks, other direct filesystem
callers (including scanning and history ownership checks), child processes,
terminal/signals, native GUI setup, DLL loading and Windows export-filename
validation still need porting. Existing Linux library filenames and source bytes
are unchanged.

`make test` includes `tests/platform.py` and `tests/files.py`, each with a standalone
Pascal probe, alongside the full integration suite. The probes isolate platform
services from the remaining Linux-only application units. The file probe can
also be compiled with a Windows Free Pascal toolchain and run natively. For Wine
on Linux, use `python3 tests/files.py /path/to/files_probe.exe --wine` with an
isolated `WINEPREFIX`; these checks supplement native Windows testing.

## Work with a library

Libraries use SQLite. The default library is `library.sqlite` in the current
directory.
To select another library, put its filename before the command, or use
`library_name=PATH`, `ln=PATH`, or `--library PATH`. SCU uses the filename
with `.sqlite` appended when no extension is supplied. Any other extension is
an error; `.sqlite` is matched case-insensitively. The containing directory
must already exist.

```sh
scu project.sqlite initialize_library
scu project inil  # also selects project.sqlite
scu ln=project.sqlite display_deck_list
scu ln="project library.sqlite"
```

Use `.sqlite` for every library filename. For example, `scu project inil`
creates `project.sqlite`; `scu project.json inil` reports an extension error
and does not create a file. This rule applies to positional names, named
library arguments, and backend execution.

If you omit the command, SCU starts an interactive session for the selected
library. At a terminal, SCU runs `display_library` before the first prompt if
the library already exists. A known command or alias in the first position
takes precedence over a bare library filename. Use `ln=` to select a library
with the same name as a command.
An extensionless positional name followed by a known command is accepted,
and an existing `project.sqlite` can be opened as `scu project`. A lone
unrecognized word remains an unknown-command error unless its `.sqlite`
library already exists; use `ln=project` to open a new interactive library
unambiguously. Commands keep precedence over library names.

At the `scu>` prompt, enter one command per line. Use single or double quotes
for values with spaces, such as `extract_deck main.pas output_file="working copy.pas"`.
An assignment such as `output_file=` supplies an empty value. Attach a named
value directly after `=`, as in `ln=project.sqlite`, or use `--library project.sqlite`.
Every successful modifying command saves automatically, in both interactive and
one-shot use. New deck revisions, library metadata, and audit records commit
in one SQLite transaction before the command reports success. You can run
`edid` and `extd` repeatedly without `savl` between commands.
`save_library` (`savl`) remains available to confirm that the library is saved.
Enter `quit_session`, `quis`, or `quit` to leave. It takes no arguments; there is no
save/discard choice. End-of-input, terminal hangup, SIGTERM, and SIGQUIT also
leave previously committed changes intact.

SQLite's rollback journal and `synchronous=FULL` provide crash recovery. When
SCU reopens the library, SQLite automatically rolls back an unfinished
transaction. Commands committed before the interruption remain saved. SCU
does not replay commands, editors, or builds, and does not create a separate
pending-edit recovery file. Keep any SQLite journal beside its database after
an interruption so SQLite can recover it. Each command loads the latest
committed library while holding its lock, preserving other sessions' changes.
When reading redirected input, SCU omits the `scu>` prompt.

## Edit, build, and publish

Working sources live directly beside the SQLite library. Filenames containing
spaces, Unicode, or more than 128 bytes receive stable hashed deck IDs during a
pattern scan; their original filename bytes remain the export names. On POSIX,
backslashes, colons and line breaks are filename bytes, not directory separators.
Scans accept them; file patterns themselves remain a single-line configuration. Names such
as `Makefile` and `Main.pas` keep their case during extraction and release. Build them there using
the programming language's own include facilities. SCU does not interpret COPY
directives. A line containing `SCU_COPY` or `SCU$COPY` remains ordinary source text.

```sh
scu project.sqlite initialize_library
scu project.sqlite configure_library build_command='make'
scu project.sqlite configure_library editor='["code", "--wait"]'
scu project.sqlite edit_file_patterns
# Edit the selected working files in an external editor.
scu project.sqlite import_deck
scu project.sqlite extract_version
scu project.sqlite lock_version description="First release"
scu project.sqlite release_version
```

`import_deck` (`impd`) without a deck name scans `file_patterns` in the library
directory, importing new and changed files and recording deletion revisions for
missing tracked files. Unchanged bytes and source associations create no revision. Working-file manifest
observations are queued transactionally with the imported revision and audit,
then applied after commit, creating `.scu-exports.json` beside the library on the
first import. A later extraction or verification retries pending updates after
interruption, without writing source files. Observations for unreadable,
oversized or changed files are ignored rather than blocking other files. Those
files still need attention or explicit restoration. Ctrl+C during this refresh
stops a command file and reports that the import itself was already saved. Decks created without
a backing source file remain outside the deletion scan. With a deck name, import
one file: `import_deck main.pas source_file=main.pas`. A source filename must have
no directory component. SCU never imports a tracked generated release file as
working source.

`create_deck` (`cred`) creates an empty deck or accepts `from_file=...`.
`edit_deck` (`edid`) edits a temporary copy in the configured editor and stores
a new revision when its bytes change. GUI editors need a wait argument so SCU
knows when editing has finished. `delete_deck` (`deld`) records a deletion; older
versions retain the deck, and it can be recreated later.

### Extraction and builds

`extract_deck` (`extd`) writes one deck's original bytes. `extract_version` (`extv`)
writes the complete selected version, including inherited decks. Both use the selected revision's recorded source filename (falling back to its
deck ID when none was recorded), default to the library directory, maintain its `.scu-exports.json`,
and run the configured build command after successful extraction. COPY text and
macros are preserved in working files. No `.scu` suffix is added.

Builds run from the **library directory**, even if an explicit output path is
supplied. The shell receives the absolute output file or directory as `$1` and
empty standard input. At a terminal a build can use `/dev/tty`. `build=no` skips
the build; an empty `build_command` does nothing. A failed build retains the
extracted files and their manifest and records the failure in the audit/history.
SCU invokes a bulk build once, after all files have been extracted.

```sh
scu extract_deck main.pas
scu extract_deck main.pas revision=0.001 version=1.1 build=no
scu extract_version version=1.1
```

Existing identical files can be tracked without replacement. Differing untracked
or locally edited files require `replace=yes`. Extraction can explicitly restore
working sources; no export may overwrite SQLite storage. Separate sessions
serialize exports and builds targeting the same output directory. A build may
run a nested extraction with `build=no`, synchronously retaining the inherited
output-lock descriptor. Nested builds are rejected.

### Release publication

The library attribute `release_directory` defaults to `release`, resolved relative
to the library directory. Configure it with `configure_library release_directory=...`
or `rd=...`. The directory is created when needed and must be separate from working
sources. `build_directory` and `expand_deck` have been removed.

`release_version` (`relv`) publishes **every live deck** in the selected version,
including inherited decks, on every run. It expands only the macros below, writes
recorded source filenames, and maintains a separate `.scu-exports.json` in the release
directory. It never invokes `build_command`. There is no incremental expansion
checkpoint; the checkpoint display/reset commands have been removed.

```sh
scu release_version
scu release_version version=1.1
scu configure_library release_directory=github-release
```

Before publication completes, SCU removes obsolete regular files previously
recorded by this library in the output directory that match `file_patterns` and
are absent from the selected snapshot.
Untracked or foreign matching files are named and kept unless `replace=yes`
explicitly authorizes their removal. Keep non-source release assets outside
those patterns. Files present in the snapshot receive the selected contents; identical files
retain their inode and modification time. Unmatched files, subdirectories, symbolic links, SQLite files,
and SQLite operational files are preserved. Edited tracked release files require
`replace=yes` for replacement or deletion. Working source files are never removed
by release cleanup. All output is planned before any new file is published or
obsolete file removed.

A source named `main.pas` therefore lives beside the library as raw source and
under `release/main.pas` as a publishable copy. Review those release files before
committing or publishing them on GitHub; SCU does not upload anything.

### Release macros

Only these uppercase tokens expand, wherever they appear in the source. Comment
prefixes, line endings, binary bytes, and surrounding text are preserved. Lowercase
spellings, unknown tokens, and former macro names remain literal text.

| Macro | Value |
| --- | --- |
| `SCU$DATE` | Deck's last modification date, UTC, `YYYY-MM-DD` |
| `SCU$TIME` | Deck's last modification time, UTC, `HH:MM:SS` |
| `SCU$DATE_TIME` | Deck's complete stored modification timestamp, UTC |
| `SCU$DECK_VERSION` | Actual stored deck version, such as `1.00-0.003` |
| `SCU$VERSION` | Selected library version being published |

An inherited deck retains its modification timestamp and deck version, while
`SCU$VERSION` reflects the selected release. Re-publishing an unchanged snapshot
produces identical source bytes: macros do not use the wall-clock publication time.
Normal identifier boundaries apply, so `SCU$VERSION_SUFFIX` is not partially expanded.
A release or verification warns once when it encounters a former COPY directive;
no include expansion is performed.

## Versions and revisions

A library has a current version and a history of locked versions. Within each
version, revisions belong to individual decks. The first stored revision of a deck
is `0.000`; each edit increments it by `revision_increment` (default `0.001`).
The complete `deck_version` is `<library version>-<deck revision>`. A deck can be
inherited unchanged from an earlier version. On its first edit in a new version,
its revision starts again at `0.000`. At `0.999`, lock the library version and
create the next one before editing again.

```sh
scu lock_version description="Release notes, including multiple lines"
scu create_version 1.1
scu display_version_history limit=10 display_description=short
scu display_version
scu display_deck main.pas limit=10
scu display_deck_list
```

Lock descriptions are required; interactive sessions prompt if omitted. Lock
timestamps are recorded in UTC. `version_increment` defaults to `0.01`; explicit
version labels may be supplied to `create_version`. `display_version` lists decks
changed in that version; `display_deck_list` lists the visible snapshot. Use
`display_version_history limit=0 display_description=full` for complete history.

Extraction defaults to `version=scu$current_version`. Omit `revision` for the
latest visible deck; combine `version=1.1 revision=0.001` or use the complete
selector `version=1.1-0.001`. These are deck revisions, not internal library-wide
snapshot numbers. `scu$previous_version` selects the preceding locked version.
Bulk extraction and publication select library versions only. The older
`scu$latest_version` spelling still selects the complete current snapshot.

`display_deck_diff` (`disdd`) compares two deck versions; defaults are
`scu$previous_deck_version` and `scu$current_deck_version`. `display_version_diff`
(`disvd`) compares complete snapshots, including added and removed decks, with
current/previous library-version defaults. Both compare original stored source,
ignore changes in whitespace amount by default (`diff -b` semantics), and produce
normal diff output. Use `ignore_space_changes=no` or `output_format=unified` to
change that behavior. Textual unified version diffs use `a/` and `b/` source
filenames, with versions in tab-separated metadata. To produce an exact textual
patch for `patch -p1`, specify **both** `output_format=unified` and
`ignore_space_changes=no`. The default whitespace-insensitive comparison is for
review; it may omit changes and does not guarantee the target bytes. Patch
application covers textual content at stable filenames; filename changes and
empty-file lifecycle require separate handling. Diff search is bounded at 3,072 edits and 256 MiB of search work;
a limit produces a complete replacement rather than minimal hunks. Diffs are generated directly in Free Pascal without GNU
diff or temporary files. `deck_name` defaults to `scu$last_modified_deck` for
single-deck display, diff, edit, and extraction commands.

## Interactive editing and command syntax

Use positional parameters, `name=value`, or `--name value` for every argument.
Strings may be quoted or unquoted; embedded whitespace needs quotes. Argument
aliases and enum values are defined in `commands.json`. Quote `scu$...` selectors
in a shell to prevent shell-variable expansion. Required arguments prompt in
interactive mode and report errors in batch mode; Ctrl+C cancels a prompt.

SCU's Free Pascal line editor provides cursor editing, persistent Up/Down history,
Ctrl+R reverse search, and Tab completion of commands, parameter names, aliases,
decks, versions, revisions, and paths. Completion uses the selected snapshot and
omits parameters already supplied through any spelling. A second Tab lists
aligned matches; tall lists paginate with Space/Tab, Enter, and Q/Esc. Resizing
restarts the page at the new dimensions while retaining the command draft. Ctrl+C
cancels the current input or operation. No GNU Readline dependency is required.

## Verify extracted and released files

Every output directory has its own JSON `.scu-exports.json`. Each record stores
the library, deck, selected version, actual deck version, mode, checksum, and
expansion metadata. Filenames and library paths retain their exact byte identity
separately from readable UTF-8 labels. Legacy manifest formats remain readable.

Before exporting a batch, SCU stages rendered bytes in a private PID-tagged
`.scu-stage-*` directory inside the output directory and writes one intent array.
A held file lock identifies a live stage, independently of local PIDs, including
on shared filesystems with working advisory locks. Recovery removes unlocked
stages, leaving locked stages, links and unknown directory contents alone.
Legacy stages without an ownership marker require manual cleanup. Atomic
replacement temporaries also remain locked until publication finishes. Cleanup
opens stale temporaries and ownership markers read-only, so preserved read-only
output permissions do not prevent recovery. Identical output bytes are not
rewritten; their manifest metadata can still be refreshed. It then replaces files atomically or unlinks obsolete release
files, syncing the affected directory, and writes one completed manifest. This
avoids rewriting and syncing the whole manifest for every deck. Deletion intents
are journaled alongside writes. Builds run only after extraction completes.

After interruption, the next export or verification reconciles each intent:

- Intended new bytes, or intended absence after deletion: complete its manifest
  update, removing records for completed deletions.
- Previous bytes or previous absence: retain the previous record.
- Unexpected bytes: preserve the file and mark the export interrupted for review.

Recovery never overwrites or deletes a destination file, invokes a build, or
replays commands; it can remove dead-process private staging files.
Repeated recovery is safe. `replace=yes` permits an explicit retry of conflicting
outputs. Corrupt manifests report how to restore a backup or reset tracking.

```sh
scu verify_decks
scu verify_decks output_directory='scu$library_directory'
scu verify_decks version=1.1
```

Verification defaults to `scu$release_directory` and `scu$current_version`. It
compares raw extracts with stored bytes and releases with freshly expanded release
macros. It reports current, outdated, edited, missing, deleted, untracked,
unavailable, or interrupted files, followed by a needs-attention list explaining
each problem. A clean run ends with `No errors were found.` Problems produce a
nonzero exit status. Deleting a deck does not immediately change exports; release
publication removes obsolete matching files and records as described above.

## Export command parameters

| Command | Parameters in positional order | Default destination |
| --- | --- | --- |
| `extract_deck` (`extd`) | `deck_name`, `output_file`, `revision`, `version`, `replace`, `build` | Library directory, `<recorded source filename>` |
| `extract_version` (`extv`) | `version`, `output_directory`, `replace`, `build` | Library directory, `<recorded source filename>` |
| `release_version` (`relv`) | `version`, `output_directory`, `replace` | Release directory, `<recorded source filename>` |

Defaults are `deck_name=scu$last_modified_deck`, `version=scu$current_version`,
`replace=no`, and `build=yes` for extraction. `revision` is optional. An explicit
`output_file` is honored unchanged. Both bulk commands export complete snapshots.
Use `display_command` for argument aliases, types, descriptions, and examples.

## Configure external-editor file patterns

The library-wide `file_patterns` attribute is a JSON list, empty by default.
Use `edit_file_patterns` (`edifp`) to open the list in the configured editor,
with one wildcard or exact filename per line:

```text
*.pas
*.inc
Makefile
file with spaces.c
*.h
```

Entries select files directly in the directory containing the library. Directory
components are rejected; subdirectory support will be added later as a library
option. Surrounding whitespace and blank lines are ignored; spaces inside
filenames are preserved. Earlier libraries with subdirectory patterns can still
be opened and edited, but importing that selection raises an error until the
patterns are corrected.
No quoting is needed in the list, and lines beginning with `#` are filenames,
not comments. Absolute paths and parent-directory (`..`) components are
rejected. No file needs to exist when its pattern is added. The edited list
is limited to 1 MiB.

```sh
scu configure_library editor='["code", "--wait"]'
scu edit_file_patterns
scu display_library
```

SCU appends a private temporary list filename to the configured editor's
arguments and waits for the editor to exit. GUI editors must be configured
with their wait option so SCU reads the saved list after editing finishes.
SCU holds the library lock while this command runs and removes the temporary
file and editor backups afterward. A successful edit saves the configuration
and audit records together; editor failures or invalid entries leave the
stored list unchanged. Saving an empty list clears it. An unchanged list does
not rewrite the library metadata. The setting is library-wide and can be
edited while the current version is locked; it creates no deck revision.

`display_library` shows the effective list. Older libraries without this
attribute use an empty list without changing their existing audited header.
This command configures the selection. Run `import_deck` (`impd`) without
arguments whenever you want to snapshot those files; no background watcher is
needed.

## Import a directory-based version archive

`tools/import_versions.py` imports an SCU directory containing numbered
`MAJOR.MINOR` subdirectories and a shared `HISTORY` file. It requires Python
3.9 or later and a built SCU executable. Preview the import first:

```sh
make
python3 tools/import_versions.py /tmp2/gwies/gwd8/SCU build/gwd8.sqlite --dry-run
python3 tools/import_versions.py /tmp2/gwies/gwd8/SCU build/gwd8.sqlite
```

Version directories are sorted by exact numeric value; their spelling is
preserved. Visible regular files are represented, including files in nested
directories. Files whose names start with a dot are skipped, as are entire
hidden directory trees (for example `.git` and `.cache`). Skipped files are
excluded from import counts, filename mappings, manifests, and deletion tracking. New files and files whose exact bytes differ from the
preceding snapshot are stored. Identical files remain inherited, retaining their
original deck version and modification time. The importer compares staged bytes,
not timestamps or SHA-1 alone, and reports stored and inherited file counts.
Files absent from the next directory receive deletion revisions, and files that
reappear are recreated even when their bytes match a previously deleted deck.
Each version's manifest still records its complete file list and checksums. All imported versions are
locked. The destination must be new and outside the source archive. The script
builds a temporary library beside the destination and publishes it only after
all versions and the audit trail have been verified. It never changes the
archive or overwrites an existing library.

The shared `HISTORY` format is:

```text
Revision: 8.001
Date: original date and time
Description: First description line
Further description lines, including blank lines.

Revision: 8.002 based on 8.001
Date: another date and time
Description: Next description
```

Descriptions run through the line before the next `Revision:` heading. Repeated
entries for a version are joined in file order with a blank line between them.
A version with no entry receives `No HISTORY description found for version X.`;
use `--strict-history` to reject those gaps instead. Lock timestamps record the
import time. Original date strings and HISTORY headings are retained in each
version's `scu-import-manifest.json` deck, alongside its exact original file
list, filename mappings, byte counts, and SHA-1 checksums.

SCU folds deck names to lowercase and restricts their characters. Plain file
names use that lowercase form. Nested paths, unsupported names such as
`source file.c`, case collisions, and a source file named `scu-import-manifest.json`
receive deterministic `import-file-` deck names based on the original path's
SHA-256 digest. The manifest retains the exact original spelling and path.
It is an additional deck in every imported snapshot.

The importer uses `.COMMENT` as the library's comment prefix when present,
otherwise `//`. Override it with `--comment-prefix '#'`. Other Python script options include
`--scu /path/to/scu`, `--encoding utf-8`, and `--timeout 120` (seconds per SCU
invocation). Symbolic links inside snapshots and files larger than SCU's
64 MiB limit are rejected. Do not edit the archive while importing.

For direct initialization with a different first version, SCU also supports
`initialize_library version=8.001` (`v=`); the default remains `1.0`.

## Run command batches

Feed SCU one command per line through standard input:

```sh
./build/scu ln=project.sqlite < commands.scu
```

Batches stop at the first error by default, including unknown commands, invalid
arguments, and execution failures. Each successful modifying command is saved
immediately; the entire batch is not a single transaction. Commands after the
error are neither executed nor audited. To continue after errors, set the startup
option `continue_on_error=yes` (aliases `coe` and `continue-on-error`):

```sh
./build/scu ln=project.sqlite continue_on_error=yes < commands.scu
./build/scu --continue_on_error yes ln=project.sqlite < commands.scu
```

The option defaults to `no` and accepts `yes/y` or `no/n`. Put it before or after
the library selector, before any command. The exit status is 1 if any command
failed, including when execution continues. Required arguments must be supplied
in batches; SCU does not prompt for them. Blank lines are ignored.

At the SCU prompt or inside another command file, use `!filename` or
`! filename` to read commands from a file. Quote filenames containing spaces:

```text
scu> ! "release commands.scu"
```

You can also start with `./build/scu ln=project.sqlite ! commands.scu`.
`!` reads SCU commands; it does not run a shell. Files can include other command
files, up to 16 levels. Nested filenames are relative to the including file's
directory; other command paths keep their normal working-directory meaning.
Errors from a command file include its filename and line number. Each executed
command is expanded and audited normally; the `!` directive itself is not an
audited library command.

At a terminal, a completed command file returns to the prompt. On the first
error, SCU abandons the current file and its enclosing command files and returns
to the prompt, keeping all earlier successful commands saved.
`continue_on_error=yes` instead processes the remaining lines. Ordinary commands
typed at the prompt continue to return to the prompt after errors. `quit_session` exits
the whole session, including from a command file.

## Command definitions

`display_command_list`, `discl`, and `help` show commands in alphabetical order
by full name. Each row lists the command name and its aliases, separated by
commas. The longest such list sets the description column. In a terminal,
descriptions wrap to fit and continuation lines align with that column. On
narrow terminals, descriptions start on an indented line below the command.
Redirected output keeps one row per command.
For detailed help, give `display_command` a command name or alias. Its
heading uses the same name and alias format. Help text and descriptions
wrap at the terminal width and keep their indentation. Example commands
stay on one line for copying.

```sh
scu discl
scu display_command command_name=extract_deck
scu display_command cn=extd
```

The bundled `commands.json` lists commands alphabetically by full name and
sorts alias lists alphabetically. Each command has one ordered `arguments`
list; all its parameters support positional and named input. Run
`make format-commands` after editing the catalog to restore command and alias
order. The target uses Python 3 and preserves the complete argument order. Detailed help comes from the
command's `help` text or a `help_file` path relative to the SCU executable.
Each argument defines its name, type, aliases, short description,
and `value` rule. Detailed help and interactive prompts show the parameter
signature followed by its description, for example
`version (v) : string = scu$optional`. Interactive prompts wrap to fit the
terminal and preserve the description's indentation on continuation lines.
Set `value` to `"scu$required"`, `"scu$optional"`, or a literal string or number
to use as the default. Yes/no switches use `enum` with `yes` (`y`) and `no`
(`n`) choices and string defaults such as `"yes"`; the separate `boolean`
argument type has been replaced by enums.
Set `"prompt_for_default": false` to apply a configured
default automatically in interactive mode.

An `enum` accepts a value name or alias from its `values` array. Each entry is
a string or an object with `name` and `aliases`. The list must be nonempty; all
names and aliases must be nonempty and unique within the enum, ignoring case,
with no control characters or surrounding whitespace. Internal spaces are
allowed; quote those names or aliases when entering a command. Values and
aliases match case-insensitively and normalize to the full declared value
before execution and auditing. Defaults can also use aliases and normalize in
the same way. `scu$required` and `scu$optional` retain their usual meanings.
For example:

```json
{
  "name": "display_description",
  "type": "enum",
  "values": [
    {"name": "short", "aliases": ["s"]},
    {"name": "full", "aliases": ["f"]}
  ],
  "aliases": ["dd"],
  "value": "short",
  "prompt_for_default": false,
  "description": "Show the first description line or the complete description."
}
```

Enums work with every argument syntax. Detailed help and argument
prompts display `enum [short (s), full (f)]`, and Tab completes names and
aliases. Keep the order of enum values as desired; `make format-commands`
preserves it while sorting each value's aliases. The diff commands'
`output_format` is also an enum, with values `[normal, unified]`.

All yes/no switches, including `build`, `continue_on_error`, and
`ignore_space_changes`, use the same enum mechanism:

```json
"values": [
  {"name": "yes", "aliases": ["y"]},
  {"name": "no", "aliases": ["n"]}
]
```

For example, `build=n` is passed to the backend and audited as `build=no`.


Full command names use `verb_noun` form, with additional words where needed.
Every command has a NOS/VE-style abbreviation: the first three letters of the
verb followed by the first letter of each remaining word. For example,
`create_deck` becomes `cred`, `display_deck_list` becomes `disdl`, and
`display_deck_diff` becomes `disdd`. The catalog tests check this convention
for every command.

The shipped catalog keeps each command's standard abbreviation, with two
convenience aliases: `help` for `display_command_list` (`discl`) and `quit` for
`quit_session` (`quis`). Spellings such as `dd`, `ddl`, `deck_history`, `init`,
`modify_library`, and `q` are not command aliases. Use `disd`, `disdl`, `inil`, `conl`, and
`quis`, or their full command names. Argument names and enum values can still
have their own aliases as defined in the catalog.
Canonical names are used when dispatching commands and recording the audit trail.

```json
{
  "name": "display_deck",
  "aliases": ["disd"],
  "summary": "List a deck's revisions with version and UTC modification time, newest first.",
  "arguments": [
    {
      "name": "deck_name",
      "type": "string",
      "aliases": ["deck", "dn"],
      "value": "scu$required",
      "description": "Name of the deck whose revision history to show.",
      "completion": "deck"
    }
  ],
  "help": "Show each revision of the named deck with its version and UTC modification timestamp."
}
```

Argument aliases are scoped to the command that defines them. The parser accepts
`string`, signed decimal `integer`, finite `float`, and `enum` values. Floats
use a decimal point regardless of the system locale. Quote strings in the shell when they contain spaces, as in
`scu extd dn=main.pas output_file="working copy.pas"`. The shorter
`output` and `o` spellings still work. For example, `"value": 1` on the
`revision` argument sets revision 1 as its default. The optional `completion`
field selects a value source such as `deck`, `version`, `revision`, `deck_version`,
`file`, `directory`, or `command`. A command's `exclusive_arguments` lists
groups of arguments that can be used one at a time. `display_command` shows
these groups, and Tab completion hides the alternatives after a selection.
The optional `examples` list pairs commands with descriptions in detailed help.
Detailed help also displays each parameter's
description, type, aliases, required or optional status, and default. SCU requires
command catalog format 4.

## Storage and audit

SQLite stores each deck revision as JSON with a base64-encoded zstd
frame, a SHA-1 checksum, and a byte count for the original source. Deletion
revisions add `deleted: true` and carry an empty source. SQLite indexes the
deletion flag so snapshot listings do not need to load source payloads. Existing
libraries gain the index on their next write without changing the bytes covered
by previous audit digests. SCU verifies
the checksum and byte count on read. The revision reader extracts plain
base64 strings before parsing the JSON metadata and uses the full parser for
escaped JSON spellings. Decks and expanded output are limited to
64 MiB each. New source output files respect the process's umask.
Replacements retain the existing permission bits and group ownership.
If SCU cannot retain the group, the replacement fails. Libraries and lock files
are created with private permissions. Release macro expansion also enforces the output limit.

SCU serializes library commands with a sibling `PATH.lock` file. The file stays
on disk so concurrent commands use the same lock. SCU releases the lock when
the command finishes. `show_history` reads a SQLite snapshot without taking
that lock. SQLite stores each revision in a separate row and keeps
audit records in the database. A save commits library changes and the command's
audit records in one transaction. If writing the successful outcome fails, SQLite rolls back
the changes and their audit attempt. The failed command leaves no pending
in-memory changes; correct the error and run the command again.

The audit trail includes failed commands that reach an initialized log and
can record their outcome. Help commands, command-line parsing errors, checks
for missing or busy output directories,
`show_history`, `verify_audit`, and interactive `quit_session` do not append
records. Successful modifying commands are already saved when their outcomes
are recorded. The log records arguments, the effective
user ID, UTC timestamps, and outcomes. The begin record uses the command
object's full name, bound arguments regardless of the abbreviations
entered. `provided_arguments` identifies positional parameters supplied in the
command, which lets the audit distinguish a supplied value from the same default.
`display_deck_list` and `extract_deck` also record the
resolved `snapshot` in their outcome, with its `version` and internal
`library_revision`. Extraction also records the actual root
`deck_version` and resolved deck name. This includes the default snapshot and attempts that
fail after SCU resolves the snapshot.
`display_deck_diff` records its resolved labels as `from_deck_version` and
`to_deck_version`. Commands using `scu$last_modified_deck` record its resolved
name as `resolved_deck`. File extraction and expansion also record the
absolute `output_path`, or the `output_directory` for a batch.
An existing attempt without a recorded outcome is counted as interrupted.
For modifying commands, the attempt, outcome, and library changes share one
SQLite transaction: a killed process rolls back that entire transaction, including
its attempt record. The audit therefore records committed work, rather than
every process invocation.

Each audit line contains a lowercase SHA-256 digest, a space, and the JSON
event. The chain uses no secret key. The digest covers the literal
`SCU audit v1 ` prefix, the previous digest (64 zeros for the first line), a
space, and the exact JSON bytes. The chain detects changed records. Save a
verified head somewhere independent of the library, then check it later.

```sh
saved_head=$(scu verify_audit | sed 's/.*head=//')
scu verify_audit --head "$saved_head"
```

Verification accepts later entries as long as the saved head still appears in
the verified chain. A person with write access to the entire log can rewrite
the chain or remove complete entries from its end. An independently saved
head detects changes to the chain through that checkpoint. New saves record
SHA-256 digests of the header and newly saved deck revisions. `verify_audit`
checks those digests against the library. SCU preserves the serialized field
order and extra JSON fields when it loads headers and revisions into the
typed library model. Older revisions without a recorded digest still have
their stored SHA-1 checked when extracted.

SCU saves the audit head and record count in SQLite in the same transaction as
each append. Ordinary commands check the tail against that state. Changes to
audit rows through SQL invalidate it and make the next command scan the chain.
`verify_audit` (`vera`) always scans the full chain and checks
recorded deck and header digests.

Run `show_history` to display the latest 20 audited command attempts in
chronological order, with canonical names, named parameters, and a
status in aligned `Command` and `Status` columns. Older audit records can still
show `pending save` from sessions that used manual saving; new successful
commands report `succeeded`. Pass a count
as in `show_history 50` or `show_history number_of_lines=50`.
The displayed parameters can include sensitive values recorded in the audit log.

## Frontend integration

At startup the CLI loads and validates `commands.json` once. Command parsing,
Tab completion, and help use the same typed definitions. Parsing and completion
also share the tokenizer and argument binder. The CLI passes a read-only
`TScuCommand` to `TScuExecutor.Execute`. Other Free Pascal frontends can
construct the same object with canonical names and bound arguments in catalog
order. Apply defaults, omit unset optional arguments, and mark explicitly
supplied values through `Provided`. There is no separate option collection.
New audit records store all bound parameters in one `parameters` object;
reading older records retains support for their original `options` fields
without rewriting the audit chain.
They can implement `TScuOutput` to capture normal output and diagnostics.

The executor selects a command handler by canonical name and passes the same
command object to the audit logger. The executor owns locking and transaction
boundaries. Handlers resolve snapshot selectors and supply the resolved values
for the executor to record in the audit outcome.

## Native GUI

The optional Lazarus frontend uses LCL/GTK2 and SynEdit. Build it with Lazarus,
its LCL GTK2 units, and the SynEdit package installed:

```sh
make gui
build/scu-gui
build/scu-gui project.sqlite
```

Keep `scu-gui`, `scu` and `commands.json` together in the build directory. The GUI
opens existing `.sqlite` libraries; create a new library with the CLI first.
The normal `make` and `make test` targets still need only the CLI dependencies.
On Ubuntu, `Failed to load module "canberra-gtk-module"` means GTK2's optional
sound module is missing; it does not prevent SCU from running. Installing
`libcanberra-gtk-module` removes the message. A GTK3 module alone does not satisfy
the GTK2 build.

- **File:** Open library, Close library, Create new version, Publish version, and Quit.
  Create new version prefills the next version using `version_increment`; the
  current version must be locked first. Unsaved buffers remain in the editor
  until explicitly saved into the new version.
- **Toolbar:** Save deck (also Ctrl+S), Extract deck, Extract version, and Close tab.
- **Left:** live decks in the current library snapshot; select a deck to open it.
- **Middle:** one SynEdit tab per deck, marked with `*` while its buffer differs
  from the stored source. Existing working text is opened when present. UTF-8
  text decks are editable; binary and other encodings are rejected by the editor.
- **Right:** a unified, exact-whitespace diff. Both selectors offer
  `scu$current_deck_version` (latest stored revision),
  `scu$previous_deck_version` (the revision immediately before it),
  `scu$live_deck_version` (the current editor buffer), and actual stored versions.
  The defaults are From=`scu$current_deck_version` and
  To=`scu$live_deck_version`, showing unsaved additions as you type. Either side
  can be changed to compare the buffer with another stored version. The preview
  refreshes after a short typing pause and follows undo. A first revision can
  compare current with live even though it has no previous revision.
- **Bottom:** canonical commands, results, errors, and streamed build output.
  Right-click for Copy and Select All. User-command failures also open a dialog
  containing the backend error; saving into a locked version keeps the buffer
  modified and explains how to create a new version.
  Commands run asynchronously; controls that could conflict with them are
  disabled while they run. Read-only comparisons keep the deck list, editor tabs
  and version selectors enabled without rebuilding the deck list. Rapid changes
  use the latest selection and discard outdated comparison results. Closing is
  refused until the command completes.

`scu$live_deck_version` is GUI-only. Live comparisons reuse SCU's diff engine
in a background worker on immutable buffer snapshots. They create no revision,
write no working file, and add no audit command. The log labels them as previews.
Stored-to-stored comparisons still submit `display_deck_diff` to the CLI.
Selecting live on both sides compares the same buffer. Save deck remains the
explicit operation that stores editor changes; saving keeps the selected preview.

Editor tabs have a highlighted active tab and a close button on each tab.
Click a tab to switch decks; Ctrl+Tab / Ctrl+Shift+Tab cycle tabs, and Ctrl+W
closes the current tab. Overflow arrows and the mouse wheel scroll long tab
strips; hovering shows the full name. Closing an inactive tab acts on that
specific deck and retains the same Save/Discard/Cancel protection for edits.

Drag the three splitters to resize panes. Window resizing preserves pane
proportions; layout minimums follow the UI font and DPI. **Edit → Preferences…**
opens a preferences dialog with **Editor** and **Library** panes. The Editor pane
has a native font picker; family, size and style apply to open and future tabs
and persist in `$XDG_CONFIG_HOME/scu/gui.json` (normally `~/.config/scu/gui.json`).
Log/diff fonts remain independent. The Library pane edits the default comment
string, external-editor argument array, build command, release directory,
version/revision increments and monitored file patterns. Only changed values are
submitted using `configure_library`. The comment string is editable only before
the first revision of an open version and applies to new decks; existing decks
retain their own prefix. Monitored patterns use one line per root filename or
wildcard. Applying them changes selection rules without importing source files.

The CLI also accepts `configure_library file_patterns='["*.pas","Makefile"]'`;
`file_patterns='[]'` clears the list. Settings and patterns save transactionally,
including when applied together. Invalid settings leave the library unchanged.

Save deck writes the working source beside the library and submits the canonical
`import_deck` command through the same `scu` executable as CLI use. Extract deck
saves its dirty tab before `extract_deck`; Extract version and Publish version
save all dirty tabs before `extract_version` and `release_version`. The backend
retains responsibility for library changes, locking, transactions, audit records,
export manifests and build execution. The GUI reads views through read-only
library/model APIs. It never issues library SQL writes. A working file changed
outside the GUI is preserved and the save stops with an explanation.

Closing a modified tab or library prompts to save, discard the **editor buffer**,
or cancel. Earlier committed library revisions remain saved. Source files are
UTF-8 and preserve LF/CRLF and final-newline state; mixed line endings normalize
when edited. Native checks cover editing, audit commands, streamed builds,
publication, font persistence, resizing, larger fonts and DPI changes:

```sh
make test-gui
```

This target requires a display; it leaves a test screenshot at
`build/gui-check.png` and uses a temporary library and temporary preferences.

## License

SCU is licensed under the GNU General Public License, version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full text.

## Historical reference

The NOS/VE manual documents `EXTRACT_DECK`, `EXPAND_DECK`, and selection
criteria for choosing decks. It also describes `INCLUDE_COPYING_DECKS` for
finding decks that include a changed common deck. This implementation's bulk
commands select decks by their stored version history.
[CDC NOS/VE Source Code Management, revision G, pp. 1-30–1-31](https://www.bitsavers.org/pdf/cdc/cyber/nos_ve/manuals/60464313G_NOS_VE_Source_Code_Management_198804.pdf)

## Review decisions and recovery notes

[Review status](REVIEW_STATUS.md) accounts for every open issue from Claude's
reviews through 5d70945, including retained design decisions.

The export manifest is private local tracking state (0600), not a required public
release artifact. Extraction restores raw bytes; release deliberately substitutes
its five macro tokens wherever they occur, including in binary decks.

Extracting an older version does not move the library's current version. A later
import records those working bytes as new revisions. Locking freezes stored decks;
import external edits before locking if they should belong to the release.

An invalid file-pattern edit is preserved in a private `scu-patterns-recovery-*`
file and the error reports its full path. Correct the retained text and copy it
back through the configured editor, then remove that recovery file and its
containing directory. Successful recovery files are retained until you have
rescued the edit; empty directories from failed recovery writes are removed.
A recovery-write failure reports both the validation error and the save error.
If an editor session is forcibly killed,
private `/tmp/scu-edit-*` working files may remain; inspect and copy valuable
edits beside the library before importing them. They are not automatically erased
because they can contain the only copy of an edit.


### Libraries made by the old archive importer

Archive imports made before b2688d9 recorded numeric staging filenames (`0`, `1`,
…) and `manifest.json` rather than their original source names. Inherited decks
can share these numbers. SCU checks the entire import-manifest deck history, even after deletion or
replacement, and refuses default source exports, bulk exports, verification and
unified version patches before publishing wrong names. A named `import_deck`
without `source_file` also reports the rebuild requirement instead of trying a
staging filename. Explicit `source_file` selection remains available. Numeric filenames in ordinary libraries remain valid. Existing audited
revisions are never rewritten or guessed from their deck IDs.

Rebuild such an archive into a **new** library with the current importer
(replace `ARCHIVE` with the source archive directory):

```sh
python3 tools/import_versions.py ARCHIVE build/rebuilt.sqlite
build/scu build/rebuilt.sqlite verify_audit
build/scu build/rebuilt.sqlite release_version
```

Keep the old database until the rebuilt snapshots and released filenames have
been checked. The importer refuses an existing destination. Rebuilding records
new import/lock timestamps and a new audit chain while retaining HISTORY text and
source bytes; it does not migrate later edits made only in the old database.
Those edits must be preserved separately before switching libraries. Single-deck
extraction to an explicit, literal `output_file` remains available for rescue:
`scu OLD.sqlite extract_deck main.pas output_file=rescued-main.pas build=no`.

Schema 7 removes obsolete expansion checkpoints and upgrades libraries in place.
This is a one-way upgrade: binaries from 6afc937 and earlier cannot reopen a
schema-7 database. Keep a separate backup if using an older binary is necessary.
