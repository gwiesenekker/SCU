# Source Code Utility

Source Code Utility (SCU) is a Free Pascal revision control tool inspired by
Control Data's NOS/VE SCU. A library holds named source decks. You can retrieve
the original bytes for editing or expand includes and macros to produce compiler
input.

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

## Work with a library

Libraries use SQLite. The default library is `library.sqlite` in the current
directory.
To select another library, put its filename before the command, or use
`library_name=PATH`, `ln=PATH`, or `--library PATH`. SCU uses the filename
as supplied. The directory containing the library must already exist.

```sh
scu project.sqlite initialize_library
scu ln=project.sqlite display_deck_list
scu ln="project library.sqlite"
```

Use a `.sqlite`, `.sqlite3`, or `.db` filename when creating a library.

If you omit the command, SCU starts an interactive session for the selected
library. At a terminal, SCU runs `display_library` before the first prompt if
the library already exists. A known command or alias in the first position
takes precedence over a bare library filename. Use `ln=` to select a library
with the same name as a command.
Use `ln=PATH` to initialize a new library with an extensionless name.

At the `scu>` prompt, enter one command per line. Use single or double quotes
for values with spaces, such as `extract_deck main.pas output_file="working copy.pas"`.
An assignment such as `output_file=` supplies an empty value. Attach a named
value directly after `=`, as in `ln=project.sqlite`, or use `--library project.sqlite`.
Every successful modifying command saves automatically, in both interactive and
one-shot use. New deck revisions, library metadata, and audit records commit
in one SQLite transaction before the command reports success. You can run
`edid`, `expv`, and your build repeatedly without `savl` between commands.
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

Use `recover_library` (`recl`) to restore an older SCU recovery file to a new SQLite
library. For a pending-only file that references saved revisions, supply a
copy of the saved SQLite snapshot from before the failed save.

```sh
./build/scu recovered.sqlite recover_library project.sqlite.recovery-TIMESTAMP.json
./build/scu recovered.sqlite recover_library project.sqlite.recovery-TIMESTAMP.json base_library=backup.sqlite
```

SCU leaves the recovery file and the base snapshot available and starts a fresh
audit trail in the restored library. Pending-only files that record an identity
and generation must match that exact base snapshot. For older files, SCU checks the saved revision count and version
history, so use a backup you know belongs to that recovery file.

SCU's Pascal line editor uses Up and Down to recall commands. Use Left,
Right, Home, End, Backspace, or Delete to edit before pressing Enter. Press
Ctrl+R and type part of a command to search saved history from newest to
oldest. Press Ctrl+R again for an older match. Enter puts the match on the
command line for editing. Esc or Ctrl+G returns to your draft. Press Tab to
complete command names, argument names, and their aliases from
`commands.json`. For example, `extd dn<Tab>` completes to `extd dn=`, and
`extd --rev<Tab>` completes to `extd --revision `. If several names match,
press Tab again to list them in aligned columns that fit the terminal.
If the list is taller than the terminal, press Space or Tab for the next
page, Enter for one more row, or Q or Esc to return to editing. The draft
and cursor position stay intact. Completion omits arguments already
supplied anywhere on the line, including those entered by alias or position.
It also honors mutually exclusive groups defined in the catalog. For single-deck
extraction and expansion, `version` and `revision` work together and both remain
available until supplied.

Tab also completes deck names, version names, and revision numbers from the
open library. For example, try `extd dn=ma<Tab>` or `extd --revision <Tab>`.
With a library version selected, deck completion includes its inherited decks.
With a deck and version selected, revision completion suggests only that deck's
stored, non-deletion revisions in that version, such as `0.000` and `0.001`.
With a revision selected, deck and version suggestions must contain that exact
deck revision; revisions are never internal library change numbers. For a diff, deck suggestions must be present at every endpoint entered
so far.
Path completion lists existing files and directories for `from_file`,
`source_file`, and `output_file`, and directories for `output_directory`. It
handles spaces in filenames and works at argument prompts as well as on the
command line.

SCU saves up to 100 recent terminal commands, each up to 64 KiB, in
`$XDG_STATE_HOME/scu/history.json`. If `XDG_STATE_HOME` is unset, SCU uses
`$HOME/.local/state/scu/history.json`. SCU skips session exit commands,
argument prompt answers, and redirected input. Dumb terminals use basic line
input.

If you leave out a required argument, SCU shows its description, expected
type, and any aliases before asking for its value. SCU usually prompts for
omitted optional arguments that have a configured default. At the
prompt, press Enter to accept the displayed default or type a different value.
Spaces are part of the value at an argument prompt. Press Ctrl+C to cancel the
pending command and return to `scu>`. One-shot invocations and redirected
scripts apply defaults automatically and report missing required arguments
as errors.

```sh
scu initialize_library
scu configure_library --editor '["vim"]'
scu create_deck main.pas
scu create_deck shared.inc from_file=shared.inc --comment-prefix '//'
scu edit_deck main.pas
scu display_deck_list
scu extract_deck main.pas working.pas
scu expand_deck main.pas compiled-main.pas
```

Deck names are case-insensitive and stored in lowercase. They begin with an
ASCII letter or digit and can also contain `.`, `-`, and `_` after the
first character. `create_deck` (`cred`) creates a new deck in the open version.
Supply `from_file` (`ff`) to use a file's bytes as the initial source, or omit
it to create an empty deck. Creating a deck with an existing name, including
an inherited live deck, is an error. `import_deck` creates a deck or adds another
revision. Imports show deck names, combined deck versions, and new/changed
status in aligned columns; unchanged source creates no revision.
`extract_deck` writes the original bytes with directives and macros intact.

`delete_deck` (`deld`) records a deletion revision in the current open version.
Its `deck_name` (`deck`, `dn`) defaults to `scu$last_modified_deck`. Deletion
hides the deck from that snapshot and from later versions that inherit it;
earlier library versions and earlier explicit revisions retain the source.
Deleting an absent deck or changing a locked version is an error. No historical
revision is physically removed.

```sh
scu delete_deck obsolete.pas
scu display_deck obsolete.pas
scu extract_deck obsolete.pas old.pas version=1.0
scu create_deck obsolete.pas from_file=replacement.pas
```

`create_deck` or `import_deck` can recreate a deleted deck under the same name.
Deletion and recreation both count as revisions: they advance the deck's
revision within the current version, and the first change in a new version
starts at `0.000`. Recreation preserves the earlier history. `display_deck`
marks deletion revisions with a final `deleted` column. Both diff commands
show removed or recreated source as deleted or added lines. Unified labels
and normal version-wide headings use `/dev/null` for the missing side;
empty-deck deletions and recreations are also reported explicitly.

Deletion does not remove files already extracted or expanded on disk. Bulk
extraction and expansion skip deleted decks. Incremental expansion still
checks their live `SCU_COPY` dependents: a reference to a deleted deck fails
expansion and leaves the checkpoint unchanged. A successful deletion-only
expansion can run the configured build and advance its checkpoint. Review or
remove obsolete output files separately when your build requires it.

Human-readable listings use column headers and aligned columns separated by at
least two spaces: deck lists and histories, version lists and histories,
expansion checkpoints, and saved command history. Raw JSON, source files, diffs,
and command help retain their respective formats. At a terminal, long deck
names and other cells wrap within their columns without truncation. Continuation
lines retain column alignment; headers can wrap too. Very narrow terminals use
stacked labelled fields. Redirected listings keep full, unwrapped cells.

`display_library` (alias `disl`) shows the selected library's path on its
opening line. The configuration follows in aligned `Attribute` and `Value`
columns, including `current_version` and `previous_locked_version` (`none`
if no earlier locked version exists), with two spaces between columns. It
includes the editor, build command, numbering increments, comment prefix, and
last modified deck. Empty string values show
`(not set)`. Values wrap under their column to fit the terminal; on narrow
terminals they move beneath the attribute. Redirected output stays unwrapped.
The `versions` array and historical descriptions are omitted, including at
interactive startup. Use `display_version_history` (`disvh`) for history.
SCU records the resolved snapshot in the audit log without changing the stored
configuration.

`show_library` prints the header as standalone JSON. It contains the current
version, numbering increments, default comment prefix, `last_modified_deck`,
the editor, build command, and version history with lock states and base
revisions. The initial default
prefix is `//` and the default editor is `vi`. Use `scu configure_library --comment-prefix '#'`
before the first revision in a version to set the default for new decks. A new
version inherits the previous default.

`edit_deck` opens an existing deck in the configured editor. SCU invokes the
editor directly with the configured arguments and appends the working file
path. For an editor that normally returns immediately, configure its wait flag,
for example `scu configure_library --editor '["code","--wait"]'`. SCU holds the
library lock while the editor is open. A successful edit creates a revision
only if the bytes changed. Review the editor setting before running
`edit_deck` on a library from someone else.

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

## Versions and revisions

`initialize_library` opens version `1.0`. Every store or saved edit belongs to the open
version. `lock_version` closes it to edits and requires a description.
`create_version` (alias `crev`) opens a higher version once the current one is
locked. Omit the version number to advance by
the library's `version_increment` (default `0.01`). For example, `1.0` advances
to `1.01`, and `1.1` advances to `1.11`. Automatic version names use at
least two fractional digits. SCU preserves existing names and compares new
versions as decimal numbers. A new library version inherits the prior snapshot.

Each deck has its own revision within a library version. The first stored
revision is `0.000`, including the first edit of an inherited deck. Each later
write advances by `revision_increment` (default `0.001`). When the next step
would pass `0.999`, lock the library version and start a new one before editing
that deck again. SCU stores the increments as decimal strings and preserves the
numbers already assigned to stored revisions. To change either increment, use
`configure_library` with `version_increment=` or `revision_increment=`.

The **deck version** joins the library version and deck revision, such as
`1.04-0.007`. The deck name identifies which history the label belongs to.
SCU still assigns a library-wide snapshot number to every stored change for
operations on the whole library. For older libraries, SCU derives deck labels
from each deck's existing history using the default step.

```sh
scu lock_version description="Initial release"
scu create_version 1.1
scu edit_deck main.pas
scu list_versions
scu expand_deck main.pas release-1.0.pas --version 1.0
mkdir raw-1.1 expanded-1.1
scu extract_modified_decks 1.1 raw-1.1
scu expand_version 1.1 expanded-1.1
```

Run `scu expand_version` (`expv`) or `scu extract_modified_decks` (`extmd`)
without arguments to use `scu$current_version` and `scu$library_directory`.
The output goes beside the selected library. Pass `output_directory=.` to write to the
shell's working directory.

For a fresh checkout of a copied library, expand every live deck at its latest
visible deck version, including inherited decks:

```sh
scu checkout/project.sqlite expand_version version='scu$latest_version'
```

`scu$latest_version` is an expansion scope selector, not a new library version.
It always writes the full live snapshot, even when the directory already has a
checkpoint. Default `scu$current_version` and named versions retain incremental
selection of decks changed in that version, with COPY-dependent refreshes.
Unrelated inherited decks are omitted from that incremental selection. A full
reset or an interrupted/failed full refresh can still require rebuilding the
whole selected snapshot. Full expansion invalidates affected directory
checkpoints before writing, including when the current version has no stored
deck changes. Failed builds preserve the last successfully built revision/time
and leave a full refresh pending.

`expand_version` replaces `expand_modified_decks`/`expmd`; the single-deck command
remains `expand_deck` (`expd`). A version expansion lists each file actually
written in aligned `Deck name` and `Deck version` columns before its summary.
The deck version is that deck's stored version, including inherited versions.
A no-change incremental run prints only the zero-deck summary. Long names wrap
to the terminal width. Every written output also updates the export manifest
with interruption recovery, its checksum, timestamp, and actual deck version;
records for untouched files are retained. Use `verify_decks` afterwards to check
all tracked outputs.

Both bulk commands use lowercase deck names as filenames and require an
existing destination directory. `extract_modified_decks` writes the latest
revision of each deck stored or edited in the specified version as
`<deck_name>.scu`. `expand_version` writes `<deck_name>`. Both commands list
each written deck and its resolved deck version in aligned columns before the
file-count summary. When no decks are written, only the summary is shown.

With the default selector or a named version, `expand_version` starts with
the decks edited in the selected version and includes their direct and indirect `SCU_COPY`
dependents, including inherited decks. Later runs use the checkpoint for that
version and absolute output directory. If no decks have changed, SCU writes
no files. A newly configured build command can build files that SCU previously
expanded without a build.
Interactive edits are saved automatically before running the batch.
SCU records `SCU_COPY` targets with each deck revision. Incremental runs use
those targets to find dependents without opening unrelated source payloads.
Revisions created before the index are scanned when first needed. A different
comment-prefix override scans the affected source to discover its targets.

The checkpoint advances with the successful build audit record. When
`build_command` is empty, it advances with the successful expansion audit
record. A failed expansion or build leaves the checkpoint in place, as does
`build=no` when a build command is configured. Switching the
comment-prefix override or overwriting a directory with a different version
can require a full refresh of the selected snapshot. Checkpoints assume the
output files stay in place between runs. A new directory starts a new batch.

Run `scu project.sqlite display_expansion_checkpoints` (or `disec`) to see
each checkpoint's version, absolute output directory, and library revision.
The status is `Incremental` or `Full rebuild pending`. The listing shows the
last actual build's revision and UTC time separately, with `None` until the
first successful build. The command uses SQLite 3.35 or later with JSON functions.

Run `scu project.sqlite reset_expansion_checkpoint 1.1 expanded-1.1`
(or `resec`) to mark that checkpoint for a full rebuild. The next
`expand_version` run for that version and directory expands every
deck in the selected snapshot, including inherited decks. The listing shows
`Full rebuild pending` until the rebuild succeeds and its audit record
commits. With no configured build command, a successful expansion clears
this status. If no
checkpoint exists for the pair, SCU reports that the pair has no checkpoint.

Each output file is replaced atomically. If a later file fails, earlier
outputs from the same command may already have been written.

`display_deck_list`, `extract_deck`, and `expand_deck` default their `version`
argument to `scu$current_version`. A library version selects its latest visible
snapshot, including inherited decks. For a single deck, `revision` identifies
that deck's stored revision within the chosen library version:

```sh
scu extract_deck moves.c output_file=moves.c version=8.1270 revision=0.001
scu expand_deck moves.c output_file=moves.c version=8.1270 revision=0.001 build=no
# Equivalent complete deck-version selector:
scu extract_deck moves.c output_file=moves.c version=8.1270-0.001
```

`revision` is an exact decimal identifier from `0.000` to `0.999`, represented
as a string rather than a floating-point number. Version and revision are not
mutually exclusive. A complete deck version already includes a revision and
cannot be combined with a separate `revision` argument. If revision is omitted,
SCU selects the latest visible revision, including an inherited deck. An explicit
revision must have been stored in the selected version; it does not select a
similarly numbered revision from an earlier version.

For expansion, the root deck can be an older revision while recursive COPY
references use the selected library version's latest visible decks. This also
applies to complete deck-version selectors. `SCU$DECK_VERSION` and modification
time macros refer to each stored deck; `SCU$LIBRARY_VERSION` refers to the
selected library version. SCU reports the selected library version, root deck
name, and resolved deck version on standard error:

```text
Using library version 8.1270, deck "moves.c", deck_version 8.1270-0.001.
```

`display_deck_list` accepts only a library version: there is no deck-wide
revision shared by every deck. Its diagnostic reports only the selected version.
Library-wide change numbers remain internal to storage, audit snapshots,
recovery, and expansion checkpoints. Neither `revision` nor `version` accepts an
internal change number as a snapshot selector. The audit outcome records both
the selected library snapshot and the actual root `deck_version` for extraction
and expansion, including inherited decks and automatically saved interactive edits.

`display_version` (alias `disv`) lists decks changed in a library version.
The `version` argument (alias `v`) defaults to `scu$current_version` without
prompting. Use `disv 1.1`, `disv version=1.1`, or `disv --version 1.1` for a
specific version. The aligned table shows deck name, latest deck version within
that library version, UTC modification time, and stored/deleted status.
Each changed deck appears once, alphabetically. Deletions and recreations are
included; unchanged inherited decks are omitted. Interactive edits are saved and
appear immediately. This is a list of recorded changes, including edits that
restore earlier contents; use `display_version_diff` for source differences.

`display_deck` shows the 10 most recent deck history entries by default. Use
`limit=N` (alias `l`) to select a count, or `limit=0` for the complete history;
entries remain newest first. `disd main 5`, `disd main l=5`, and
`disd main --limit 5` are equivalent.

`display_library` shows only the library path on its opening line. Its aligned
Attribute/Value table includes `current_version` and `previous_locked_version`
(the locked predecessor of the current version, or `none`).

`display_deck_list` shows aligned `Deck name` and `Deck version` columns in the
selected snapshot, with at least two spaces between columns and headers even
when the snapshot is empty. Inherited decks show the version where they were last changed.
`list_versions` reports each library version and its lock state.
Use `display_version_history` (alias `disvh`) to show the 10 most recent
versions, including the current one, in chronological order. Each row shows its
lock status, UTC lock timestamp, and the first description line by default.
Set `limit=N` (alias `l`) for a different count, or `limit=0` for all versions.
The limit is a nonnegative integer and applies without prompting. Counts larger
than the history show every available version.
The positional order is `display_description` followed by `limit`, so
`disvh short 0` and `disvh dd=s l=0` are equivalent. All arguments can also be named with `name=value` or `--name value`.
Help lists the ordered parameters under Arguments; there is no separate
Options category.
Use `display_description=full` (alias `dd`) to include the complete description,
or `display_description=short` to select the default explicitly:

```sh
scu disvh
scu disvh display_description=full
scu disvh dd=short
scu disvh limit=5
scu disvh short 0
scu disvh f 5
scu disvh limit=0 display_description=full
```

History columns are aligned with spaces, using two spaces between columns
rather than tab characters. Version names and timestamps determine the column
widths; longer version names remain aligned. At a terminal, descriptions absorb
wrapping first so version names, status, and full UTC lock timestamps stay
together. Very narrow terminals use labelled fields; timestamps appear on their
own line when they fit there. Redirected output remains unwrapped.

The option is an enum with values `[short (s), full (f)]`; `s` and `f` are value
aliases. For example, `disvh dd=f` shows complete descriptions. It applies its default without
prompting. Full descriptions escape embedded line breaks as `\n` (or `\r\n`),
keeping one output row per version. Description text stored in the library is
unchanged. For example, run
`lock_version description="Ready for release"`. Interactive SCU prompts for
an omitted description. Scripted commands must supply it. Older locked versions
without a recorded timestamp show `None` and an empty description.

## Inspect and compare decks

`display_deck_diff` (`disdd`) and `display_version_diff` (`disvd`) ignore
changes in the amount of whitespace by default, like GNU `diff -b`. Runs of
one or more spaces, tabs, vertical tabs, form feeds, or carriage returns compare
as a single space; trailing whitespace is ignored. LF and CRLF endings and a
missing final newline compare equally when the line contents otherwise match.
Adding or removing a blank line remains a change. A separator present on only
one side remains significant: `a b` and `a   b` compare equally, while `ab` and
`a b` differ. The comparison is textual, including inside quoted strings;
binary decks still receive an exact binary-difference notice.

Set `ignore_space_changes=no` (`isc=n`) for exact comparison. This yes/no enum
option defaults to `yes` without prompting in interactive sessions. For example:

```sh
scu disdd main.pas
scu disdd main.pas ignore_space_changes=no
scu disvd 1.0 1.1 isc=n
```

Both diff commands default to `output_format=normal` (`format`, `of`). Normal
output shows changed lines only, using `a` for additions, `d` for deletions,
and `c` for replacements. Old lines have a `< ` prefix and new lines a `> `
prefix. For example, a change to the first line appears as:

```text
1c1
< previous text
---
> replacement text
```

Use `output_format=unified` (`of=unified`) for `---`/`+++` file labels, `@@`
hunk ranges, and three unchanged context lines. Format selection does not
prompt in interactive mode. A normal version-wide diff identifies each changed
deck with a `diff OLD_LABEL NEW_LABEL` heading. A single-deck normal diff has
no file heading, matching normal GNU diff output; resolved deck versions still
appear on standard error.

```sh
scu disdd main.pas output_format=unified
scu disvd 1.0 1.1 of=unified
```

Both formats retain the original source lines. Neither format changes the
stored decks or ignores legacy revision header text.


`display_deck` identifies the resolved deck name above its history table,
including when the name defaults to `scu$last_modified_deck`. It shows aligned
columns headed `Deck version`, `Modified (UTC)`,
and `Status`, newest first. The status is `stored` or `deleted`. The deck
version identifies the owning library version and per-deck revision, so the
internal library-wide revision number is omitted from this display. The following forms are
equivalent.

```sh
scu display_deck deck_name=main.pas
scu disd dn=main.pas
scu disd main.pas
scu disd main.pas
```

`display_deck`, `display_deck_diff`, `edit_deck`, `extract_deck`, and `expand_deck`
default to `scu$last_modified_deck` without prompting for the deck name.
The selector uses the latest visible deck in the current library version, including automatically saved
changes in an interactive session. It can also be supplied explicitly as
`deck_name='scu$last_modified_deck'`. SCU reports an error if the library is
empty. Older libraries derive the attribute from their revision history.

`extract_deck` defaults `output_file` to `scu$deck_name.scu`, producing a raw
`<deck_name>.scu` file in the current directory. `expand_deck` defaults to
`scu$deck_name`, producing `<deck_name>`. Thus extracting `main.pas` does not
overwrite an expanded `main.pas`; it writes `main.pas.scu`. An explicit
`output_file` is used exactly as supplied. `extract_modified_decks` defaults its version to `scu$current_version` without
prompting and writes `<deck_name>.scu`, while `expand_version` writes `<deck_name>`.
Both forms are recorded separately in the export manifest.

`import_deck` (`impd`) combines the former import and store commands. With
`deck_name`, it creates, updates, or recreates a deck in the current unlocked
version. `source_file` is optional: it defaults to the deck's recorded source
filename in the library directory, or the deck name for a new or older deck.
`source_file` must be a bare filename: absolute paths, `./file`, `../file`,
subdirectory paths, and Windows-style directory components are errors. The
file is resolved beside the library, even when SCU runs from another directory.
Tab completion offers files there and excludes directories. An
explicit source filename and extension do not determine the deck name or
change an existing source-path association. Supplying `source_file` without
`deck_name` is an error. Exact byte equality and unchanged comment prefix and
source-filename association leave the deck revision untouched, including inherited decks. New decks and
the first changed revision in a new library version start at `0.000`.
Existing comment prefixes are retained unless overridden.

Without `deck_name` or `source_file`, `impd` snapshots `file_patterns` in the
**library directory**, regardless of SCU's working directory. It creates decks
for new files, revises changed files, and adds deletion revisions for missing
live decks whose source paths match the current patterns. Earlier source
remains available and a returning file recreates the deck. Decks outside the
current patterns are preserved; reducing or clearing the patterns does not
delete them. An empty pattern list is a harmless no-op. File contents are
compared rather than modification times. Each changed deck is listed with
its deck version and `new`, `changed`, or `deleted` status, followed by counts
including unchanged files. A no-change run prints only the counts.

Wildcards support `*`, `?`, and bracket expressions in filenames. Only files
directly beside the library are scanned; SCU never descends into subdirectories,
and patterns containing directory components are rejected. Matching is
case-sensitive, while deck names remain lowercase. Original source filenames
are recorded with revisions so their case is preserved for later scans. Two
selected files mapping to the same deck name are an error. Selected filenames
must satisfy the deck naming rules; use a named
import for arbitrary source filenames. Hidden entries require a pattern that
explicitly begins with a dot, and still must satisfy the deck naming rules.
Directories, the active library's SQLite files and lock, and the export
manifest are excluded. Selected symlinks, scan/read errors, invalid filenames,
revision-limit failures, and audit-write failures abort the whole snapshot;
no partial set of revisions is saved. Exported files and export manifests
are not changed by imports or deletion revisions.

The command and all new, changed, and deleted revisions save together with
the audit records in one SQLite transaction. The former `store_deck`/`stod`
command has been removed; existing audit records keep their original names.
Imports and edits save automatically in interactive sessions and one-shot use.
You can run `expand_version` or `extract_modified_decks` immediately afterward.

```sh
scu extract_deck main.pas
# Edit main.pas.scu, then import it:
scu import_deck main.pas main.pas.scu
# An arbitrary filename works equally well:
scu import_deck main.pas source_file=edited.txt
# Snapshot all selected files after editing in an external GUI:
scu import_deck
```

Use `scu disdl` for `display_deck_list`. Every parameter is an argument and
accepts positional values, `name=value`, or `--name value` (also `--name=value`).
Argument aliases work in both named forms. Named and positional input can be
mixed: positional values fill the next argument not already supplied by name.
Use `--` before positional values that could otherwise be parsed as named
arguments. Omitted optional arguments without defaults are left unset.

```sh
scu display_deck_diff
scu display_deck_diff main.pas
scu display_deck_diff main.pas 1.04-0.006 1.04-0.007
scu display_deck_diff main.pas 1.04-0.006 'scu$current_deck_version'
```

Each endpoint accepts a deck version or one of two selectors.
`scu$current_deck_version` selects the latest version of the deck, and
`scu$previous_deck_version` selects the preceding version, including across
library version boundaries. By default, SCU compares those two deck versions.
If you supply `to_snapshot` and omit `from_snapshot`, SCU compares with the
deck revision immediately before the selected one. Use single quotes around
selectors such as `'scu$previous_deck_version'` in a shell. `extract_deck` and `expand_deck`
also accept a deck version as `--version` for the named deck.
SCU compares the deck as it exists in each snapshot, including inherited source.
SCU generates normal or unified diffs directly in memory, keeping COPY
directives and macros intact. If the search reaches its limit of 3,072 line
edits or exhausts its search budget, SCU keeps the shared beginning and end
and reports the rest as one replacement. Decks containing NUL bytes are compared as binary data. A completed
comparison exits successfully even when differences are found. Identical
source produces no diff. SCU reports both resolved deck versions on standard
error and uses them in patch labels. An inherited deck shows the label from
the library version where it was last changed. Each endpoint must identify a
stored deck revision, which can be a source revision or a deletion revision.

Use `display_version_diff` (alias `disvd`) to compare every deck across
two library versions. Its `from_version` defaults to `scu$previous_version`,
the locked version before the current version. Its `to_version` defaults to
`scu$current_version`, including automatically saved interactive edits.

```sh
scu display_version_diff
scu display_version_diff 1.0 1.1
scu display_version_diff from_version=1.0 to_version='scu$current_version'
```

Only changed source produces a diff. Inherited decks participate in each
snapshot, and added or removed source is compared against `/dev/null`.
Added or removed empty decks have an explicit notice. Patch labels identify
the stored deck versions. SCU reports and audits the selected library versions.

`display_deck_diff` also accepts the alias `disdd`.

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

## Expand source

A directive starts with the deck's comment prefix after optional indentation.
Set it with `--comment-prefix PREFIX` on `create_deck` or `import_deck`.
Subsequent stores and edits inherit the deck's prefix, and a new prefix on
`import_deck` applies from that revision onward. Each deck visited by COPY uses
its own prefix at the selected snapshot. Older entries without a stored deck
prefix use the selected version's default.

Use `--comment-prefix PREFIX` on an expand command to temporarily override all
prefixes for that export. Directive and macro names are case-sensitive.

```pascal
program Example;

const
  ReleaseVersion = 'SCU$VERSION';
  SourceModified = 'SCU$DATE SCU$TIME UTC';

//SCU_COPY shared.inc

begin
  WriteLn(ReleaseVersion, ' ', SourceModified);
end.
```

`SCU_COPY` replaces its directive line with the expanded source of the named
deck. COPY can nest, and every lookup uses the same library snapshot. SCU
reports missing decks and cycles with the source deck and directive line.

Set `build_command` with `configure_library` (`conl`).
Both `expand_deck` and `expand_version` run the configured command after
writing their output. `build=no` skips the build. A bulk expansion runs the
command once when it writes at least one deck or a previous SQLite expansion
is waiting to be built. The shell runs in the current working directory and
receives the absolute output file or directory as `$1`. Builds receive empty
standard input. At an interactive terminal, a build can prompt through `/dev/tty`.
SCU restores the terminal after the build. Review the build command before
expanding a library from someone else, or use `build=no` to expand without
running it.

```sh
scu configure_library build_command='cc "$1" -o main'
scu expand_deck main.c compiled-main.c
scu expand_deck main.c compiled-main.c build=no
```

Use `configure_library build_command=` to clear the command. If the build fails,
the expanded output remains available and SCU records the build outcome.

Independent expansions targeting the same directory wait for each other,
including while a build runs. A build can run `expand_deck ... build=no` in
its own output directory. Run the nested command synchronously and preserve
the inherited directory lock descriptor. For Python's `subprocess` module,
pass the descriptor named by `SCU_BUILD_OUTPUT_LOCK_FD` via `pass_fds`.
An SCU command launched by a build fails immediately if its output directory
is busy, unless it can reuse the inherited lock. Use `build=no` for nested
expansions. If a background build needs terminal input, SCU suspends with it
until it is resumed with `fg`. A build that already holds a directory lock gets an error if it invokes
`expand_version` or `reset_expansion_checkpoint` in that directory.

- `SCU$DECK_VERSION` is the combined version and revision of the deck being
  expanded, such as `1.1-0.003`. Included decks use their own stored versions.
- `SCU$LIBRARY_VERSION` is the selected library version, even when expanding an
  older root deck revision or a deck inherited from an earlier version.
- `SCU$LAST_MODIFIED_DATE`, `SCU$LAST_MODIFIED_TIME`, and
  `SCU$LAST_MODIFIED_DATE_TIME` use the stored modification time of the deck
  being expanded, including each copied deck.
- `SCU$EXPANSION_DATE`, `SCU$EXPANSION_TIME`, and `SCU$EXPANSION_DATE_TIME` use
  one timestamp for the whole expansion command, including its COPY and bulk
  outputs. A file skipped by incremental expansion retains its earlier timestamp.
- Dates use `YYYY-MM-DD`, times use `HH:MM:SS`, and combined timestamps use
  `YYYY-MM-DDTHH:MM:SS.sssZ`. All values are in UTC.
- `SCU$DATE` and `$SCU_DATE` are aliases for `SCU$LAST_MODIFIED_DATE`.
  `SCU$TIME` and `$SCU_TIME` are aliases for `SCU$LAST_MODIFIED_TIME`.
  `SCU$VERSION` and `$SCU_VERSION` are aliases for `SCU$LIBRARY_VERSION`.
  A line that starts with the comment prefix immediately followed by a macro,
  such as `//SCU$DECK_VERSION`, has that prefix removed. Inline macros are
  replaced in place, with quoting supplied by the surrounding source.

SCU records a deck's modification timestamp when its revision is stored.
Repeated expansions of the same locked version with the same options produce
the same bytes when the source and its COPY dependencies are unchanged and
do not use `SCU$EXPANSION_*` macros.

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
are created with private permissions. Expansion also caps nesting and total
source processed.

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
`display_deck_list`, `extract_deck`, and `expand_deck` also record the
resolved `snapshot` in their outcome, with its `version` and internal
`library_revision`. Extraction and expansion also record the actual root
`deck_version` and resolved deck name. This includes the default snapshot and attempts that
fail after SCU resolves the snapshot.
`display_deck_diff` records its resolved labels as `from_deck_version` and
`to_deck_version`. Commands using `scu$last_modified_deck` record its resolved
name as `resolved_deck`. File extraction and expansion also record the
absolute `output_path`, or the `output_directory` for a batch.
An attempt without a recorded outcome
is counted as interrupted.

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

## Verify exported decks

Extraction and expansion maintain `.scu-exports.json` in each output directory,
including batch commands. Each file record stores its library path, deck name,
selected library version, actual deck version, extraction/expansion mode,
SHA-256 checksum, expansion timestamp, and temporary comment-prefix override.
Updates are atomic and serialized with exports to that directory. Before
replacing an output, SCU saves a `pending` record in the same JSON manifest. It
contains the intended export metadata and checksum, plus the checksum of the
existing output (an empty value means the file did not exist). SCU then replaces
the output atomically and commits its file record, removing `pending`.

The next export or `verify_decks` in that directory automatically reconciles an
interrupted operation under the directory lock:

- If the output matches the intended checksum, SCU completes the manifest update,
  retaining the original expansion timestamp and comment-prefix override.
- If the output still matches its previous checksum or previous absence, SCU
  discards the unpublished intent and preserves the previous manifest records.
- If it matches neither, SCU leaves the output untouched and retains its intended
  provenance as an `interrupted_export` file record. Verification reports
  `interrupted export` along with any missing, outdated, or locally modified
  status and fails. An explicit re-export of that file resolves the flag.

Recovery never restores or overwrites an output file. Repeated recovery is safe,
including when recovery itself is interrupted. Unrelated exports can proceed
while another file needs attention. An interrupted retry retains the earlier
unresolved record until a new export succeeds. Partial batches retain records
for outputs already written, and recovery does not run builds or advance SQLite
expansion checkpoints. A failed build can still leave correctly tracked
generated files; checkpoints continue to advance only
under their existing success rules.

```sh
scu verify_decks
scu verd output_directory=build version=1.1
```

`verify_decks` (alias `verd`) defaults to `scu$library_directory` and
`scu$current_version`. It checks the latest visible deck in the selected version,
not the historical revision that was originally exported. Extraction is compared
with original source; expansion is compared with freshly and recursively expanded
COPY directives and macros. The recorded expansion timestamp is reused, so
`SCU$EXPANSION_DATE`, `SCU$EXPANSION_TIME`, and `SCU$EXPANSION_DATE_TIME` do not
produce false differences. The prefix override is also reused. Verification
never rebuilds or overwrites exported files. It may repair manifest metadata
when recovering an interrupted export.

The aligned report uses compact `File`, `Mode`, `Exported`, `Latest`, and
`Status` columns. Both version columns contain deck versions. Tracked files are
sorted by filename. The file identifies the deck for normal output names;
custom file-to-deck mappings appear below the table. Long error explanations
also appear below the table and wrap to terminal width, so they cannot squeeze
every filename into a narrow column. Compact statuses include `current`,
`outdated`, `edited`, `outdated+edited`, `missing`, `deleted`, `unavailable`,
`untracked`, and `interrupted`. Detailed explanations retain the full locally
modified, interrupted, or expansion-error information. After checking every
file, a final `Needs attention:` list names each affected deck and file with its
full reason. It includes version differences, COPY/macro output changes, missing
files, checksum differences, deletions, interrupted exports, and absent tracking
records. Current files are omitted from that final list. Long explanations wrap
to the terminal width. Per-file read errors are reported while other files
continue to be checked; the command still returns a failing status for problems.

`delete_deck` changes the library and preserves its history. It does not remove
exported files or their manifest records: those exports may be in other
directories or intentionally represent an older version. Verification against
a version where the deck is deleted reports `deleted`, showing the deletion's
deck version, rather than silently forgetting the obsolete file. Verification
against an earlier version can still succeed. Removing tracking alone would
hide an obsolete generated file that a build could still consume.
An unchanged root can be outdated when a COPY dependency or library-version
macro changes. A different root deck version is outdated even if its bytes match.
Any non-current file gives a failing exit status; successful verification reports
the number of checked files followed by `No errors were found.` Results and
the selected snapshot are audited.

Older exports have no provenance. Existing files whose names match known deck
names or those names plus `.scu` are reported as `untracked`; renamed older exports cannot be identified
automatically. Re-export them to establish tracking. Unrelated files and records
belonging to other libraries are not checked. The library is identified by its
canonical path, so moving it requires re-exporting to refresh the records. The
manifest filename is reserved and cannot be used as an export destination.

SCU loads `commands.json` once when starting. Restart an interactive session
after updating the executable or catalog to see the new help and parsing rules.

## License

SCU is licensed under the GNU General Public License, version 3 only
(`GPL-3.0-only`). See [LICENSE](LICENSE) for the full text.

## Historical reference

The NOS/VE manual documents `EXTRACT_DECK`, `EXPAND_DECK`, and selection
criteria for choosing decks. It also describes `INCLUDE_COPYING_DECKS` for
finding decks that include a changed common deck. This implementation's bulk
commands select decks by their stored version history.
[CDC NOS/VE Source Code Management, revision G, pp. 1-30–1-31](https://www.bitsavers.org/pdf/cdc/cyber/nos_ve/manuals/60464313G_NOS_VE_Source_Code_Management_198804.pdf)
