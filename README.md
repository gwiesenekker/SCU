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
it at startup for command names, arguments, supported options, aliases, and
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
Interactive library changes are visible in the session and stay in memory
until you run `save_library` (`savl`). Enter `quit_session`, `quit`, or `q` to
save pending changes and leave, or use `quit save_library=no` to discard changes
since the last save. End-of-input, terminal hangup, SIGTERM, and SIGQUIT also
save pending changes. If a signal-triggered save fails, SCU attempts to write a
private recovery JSON file beside the library. If the original SQLite database
is unavailable, the recovery file contains the pending revisions and header.
One-shot commands save immediately, and `initialize_library` creates the empty
library immediately.
If another session changes the saved library, a save reports the conflict.
At a terminal, SCU keeps the pending changes available at the prompt. When
reading redirected input, SCU omits the `scu>` prompt. Errors are reported and
the session continues.
The session exits with status 1 if any command failed.

Use `recover_library` (`recl`) to restore a recovery file to a new SQLite
library. For a pending-only file that references saved revisions, supply a
copy of the saved SQLite snapshot from before the failed save.

```sh
./build/scu recovered.sqlite recover_library project.sqlite.recovery-TIMESTAMP.json
./build/scu recovered.sqlite recover_library project.sqlite.recovery-TIMESTAMP.json base_library=backup.sqlite
```

SCU leaves the recovery file and the base snapshot available and starts a fresh
audit trail in the restored library. New pending-only files identify the exact
base snapshot. For older files, SCU checks the saved revision count and version
history, so use a backup you know belongs to that recovery file.

SCU's Pascal line editor uses Up and Down to recall commands. Use Left,
Right, Home, End, Backspace, or Delete to edit before pressing Enter. Press
Ctrl+R and type part of a command to search saved history from newest to
oldest. Press Ctrl+R again for an older match. Enter puts the match on the
command line for editing. Esc or Ctrl+G returns to your draft. Press Tab to
complete command names, argument names, options, and their aliases from
`commands.json`. For example, `extd dn<Tab>` completes to `extd dn=`, and
`extd --rev<Tab>` completes to `extd --revision `. If several names match,
press Tab again to list them in aligned columns that fit the terminal.
If the list is taller than the terminal, press Space or Tab for the next
page, Enter for one more row, or Q or Esc to return to editing. The draft
and cursor position stay intact. Completion omits arguments and options already
supplied anywhere on the line, including those entered by alias or position.
It also hides mutually exclusive options and their aliases. Selecting
`version` hides `revision`, and selecting `revision` hides `version`.

Tab also completes deck names, version names, and revision numbers from the
open library. For example, try `extd dn=ma<Tab>` or `extd --revision <Tab>`.
With a version or revision selected, deck completion shows only decks present
in that snapshot, including inherited decks. With a deck selected, completion
suggests the versions that contain the deck and the revision numbers recorded
for it. For a diff, deck suggestions must be present at every endpoint entered
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
omitted optional arguments and options that have a configured default. At the
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
scu list_decks
scu extract_deck main.pas working.pas
scu expand_deck main.pas compiled-main.pas
```

Deck names are case-insensitive and stored in lowercase. They begin with an
ASCII letter or digit and can also contain `.`, `-`, and `_` after the
first character. `create_deck` (`cred`) creates a new deck in the open version.
Supply `from_file` (`ff`) to use a file's bytes as the initial source, or omit
it to create an empty deck. Creating a deck with an existing name, including
an inherited deck, is an error. `store_deck` creates a deck or adds another
revision. Deck writes report the library version first, followed by the
per-deck revision and the combined deck version.
`extract_deck` writes the original bytes with directives and macros intact.

`display_library` (alias `disl`) shows the selected library's path, current
version, and previous locked version, or `none` if no earlier version exists.
The full configuration header follows the summary, including at interactive
startup. SCU records the resolved snapshot in the audit log.

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

## Versions and revisions

`initialize_library` opens version `1.0`. Every store or saved edit belongs to the open
version. `lock_version` closes it to edits and requires a description. `start_version` opens a higher
version once the current one is locked. Omit the version number to advance by
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
scu start_version 1.1
scu edit_deck main.pas
scu list_versions
scu expand_deck main.pas release-1.0.pas --version 1.0
mkdir raw-1.1 expanded-1.1
scu extract_modified_decks 1.1 raw-1.1
scu expand_modified_decks 1.1 expanded-1.1
```

Run `scu expand_modified_decks` without arguments to use
`scu$current_library_version` and `scu$library_directory`. The output goes
beside the selected library. Pass `output_directory=.` to write to the
shell's working directory.

Both bulk commands use lowercase deck names as filenames and require an
existing destination directory. `extract_modified_decks` writes the latest
revision of each deck stored or edited in the specified version.

For a SQLite library, `expand_modified_decks` starts with the decks edited
in the selected version and includes their direct and indirect `SCU_COPY`
dependents, including inherited decks. Later runs use the checkpoint for that
version and absolute output directory. If no decks have changed, SCU writes
no files. A newly configured build command can build files that SCU previously
expanded without a build.
Save pending interactive edits with `save_library` before running the batch.
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
`expand_modified_decks` run for that version and directory expands every
deck in the selected snapshot, including inherited decks. The listing shows
`Full rebuild pending` until the rebuild succeeds and its audit record
commits. With no configured build command, a successful expansion clears
this status. If no
checkpoint exists for the pair, SCU reports that the pair has no checkpoint.

Each output file is replaced atomically. If a later file fails, earlier
outputs from the same command may already have been written.

`display_deck_list`, `extract_deck`, and `expand_deck` default to the current
snapshot. Use `--version VERSION` to select a version or `--revision N` to
select a library-wide revision. These commands report the resolved version
and library revision on standard error after success. Revision 0 is the empty
snapshot, and each store or saved edit advances the revision by one.
`extract_deck` and `expand_deck` name the selected version when a deck is
missing. If you specify `--revision`, the error names that revision.
`display_deck_list` shows each deck's name and deck version in the selected
snapshot. Inherited decks show the version where they were last changed.
`list_versions` reports the version, lock state, base revision, and end revision.
Use `display_version_history` (alias `disvh`) to show each version's lock
status, UTC lock timestamp, and description. For example, run
`lock_version description="Ready for release"`. Interactive SCU prompts for
an omitted description. Scripted commands must supply it. Older locked versions
without a recorded timestamp show `None` and an empty description.

## Inspect and compare decks

`display_deck` prints the library-wide revision number, owning library version,
stored modification time in UTC, and deck version, newest first. The following forms are
equivalent.

```sh
scu display_deck deck_name=main.pas
scu disd dn=main.pas
scu disd main.pas
scu dd main.pas
```

`display_deck`, `diff_deck`, `edit_deck`, `extract_deck`, and `expand_deck`
default to `scu$last_modified_deck` without prompting for the deck name.
The selector uses the deck from the latest library revision, including pending
changes in an interactive session. It can also be supplied explicitly as
`deck_name='scu$last_modified_deck'`. SCU reports an error if the library is
empty. Older libraries derive the attribute from their revision history.

`extract_deck` and `expand_deck` default `output_file` to `scu$deck_name`,
the name of the selected deck, and write the file in the current directory. Use
`output_file=working.pas` to choose a different destination.

Use `scu ddl` for `display_deck_list`. The earlier `list_decks` spelling also
works. Named arguments can be mixed with positional arguments. Use `--`
before a positional value that could otherwise be parsed as an option or
named argument.

```sh
scu diff_deck
scu diff_deck main.pas
scu diff_deck main.pas 1.04-0.006 1.04-0.007
scu diff_deck main.pas 1.04-0.006 'scu$current_deck_version'
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
SCU generates unified diffs in memory with three lines of context, keeping COPY
directives and macros intact. If the search reaches its limit of 3,072 line
edits or exhausts its search budget, SCU keeps the shared beginning and end
and reports the rest as one replacement. Decks containing NUL bytes are compared as binary data. A completed
comparison exits successfully even when differences are found. Identical
source produces no diff. SCU reports both resolved deck versions on standard
error and uses them in patch labels. An inherited deck shows the label from
the library version where it was last changed. The deck must exist at both
endpoints.

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

The bundled `commands.json` lists commands and their options alphabetically by
full name and sorts each alias list alphabetically. Run `make format-commands`
after editing the catalog to restore that order. The target uses Python 3 and
preserves the order of positional arguments. Detailed help comes from the
command's `help` text or a `help_file` path relative to the SCU executable.
Each argument or option defines its name, type, aliases, short description,
and `value` rule. Detailed help and interactive prompts show the parameter
signature followed by its description, for example
`--version (v) : string = scu$optional`. Interactive prompts wrap to fit the
terminal and preserve the description's indentation on continuation lines.
Set `value` to `"scu$required"`, `"scu$optional"`, or a literal string, number,
or Boolean to use as the default. A `boolean` parameter accepts `yes` or `y`
and `no` or `n`, case-insensitively. Its JSON default can be `true` or `false`.
Set `"prompt_for_default": false` to apply a configured
default automatically in interactive mode.

Full command names use `verb_noun` form. The spellings `init`, `configure`,
and `quit` remain aliases for `initialize_library`, `configure_library`, and
`quit_session`.

```json
{
  "name": "display_deck",
  "aliases": ["dd", "deck_history", "disd"],
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
  "options": [],
  "help": "Show each revision of the named deck with its version and UTC modification timestamp."
}
```

Argument aliases are scoped to the command that defines them. The parser accepts
`string`, signed decimal `integer`, finite `float`, and `boolean` values. Floats
use a decimal point regardless of the system locale. Quote strings in the shell when they contain spaces, as in
`scu extd dn=main.pas output_file="working copy.pas"`. The shorter
`output` and `o` spellings still work. For example, `"value": 1` on the
`revision` option sets revision 1 as its default. The optional `completion`
field selects a value source such as `deck`, `version`, `revision`, `deck_version`,
`file`, `directory`, or `command`. A command's `exclusive_options` lists
groups of options that can be used one at a time. `display_command` shows
these groups, and Tab completion hides the alternatives after a selection.
The optional `examples` list pairs commands with descriptions in detailed help.
Detailed help also displays each parameter's
description, type, aliases, required or optional status, and default. SCU requires
command catalog format 3.

## Expand source

A directive starts with the deck's comment prefix after optional indentation.
Set it with `--comment-prefix PREFIX` on `create_deck` or `store_deck`.
Subsequent stores and edits inherit the deck's prefix, and a new prefix on
`store_deck` applies from that revision onward. Each deck visited by COPY uses
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

Set `build_command` with `modify_library`, an alias for `configure_library`.
Both `expand_deck` and `expand_modified_decks` run the configured command after
writing their output. `build=no` skips the build. A bulk expansion runs the
command once when it writes at least one deck or a previous SQLite expansion
is waiting to be built. The shell runs in the current working directory and
receives the absolute output file or directory as `$1`. Builds receive empty
standard input. At an interactive terminal, a build can prompt through `/dev/tty`.
SCU restores the terminal after the build. Review the build command before
expanding a library from someone else, or use `build=no` to expand without
running it.

```sh
scu modify_library build_command='cc "$1" -o main'
scu expand_deck main.c compiled-main.c
scu expand_deck main.c compiled-main.c build=no
```

Use `modify_library build_command=` to clear the command. If the build fails,
the expanded output remains available and SCU records the build outcome.

Independent expansions targeting the same directory wait for each other,
including while a build runs. A build can run `expand_deck ... build=no` in
its own output directory. Run the nested command synchronously and preserve
the inherited directory lock descriptor. For Python's `subprocess` module,
pass the descriptor named by `SCU_BUILD_OUTPUT_LOCK_FD` via `pass_fds`.
An SCU command launched by a build fails immediately if its output directory
is busy, unless it can reuse the inherited lock. Use `build=no` for nested
expansions. A build that already holds a directory lock gets an error if it invokes
`expand_modified_decks` or `reset_expansion_checkpoint` in that directory.

- `SCU$DECK_VERSION` is the combined version and revision of the deck being
  expanded, such as `1.1-0.003`. Included decks use their own stored versions.
- `SCU$LIBRARY_VERSION` is the selected library snapshot's version. With a
  numeric revision, it is the version that owns that revision.
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
frame, a SHA-1 checksum, and a byte count for the original source. SCU verifies
the checksum and byte count on read. Decks and expanded output are limited to
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
the save and its audit attempt. An interactive `save_library` keeps the
pending edits available for retry.

The audit trail includes failed commands that reach an initialized log and
can record their outcome. Help commands, command-line parsing errors, checks
for missing or busy output directories,
`show_history`, `verify_audit`, and interactive `quit` with no pending changes do not append
records. Outcomes against a working library with unsaved changes carry
`pending_save`. Quitting with pending changes records whether SCU saved or
discarded them. The log records arguments, the effective
user ID, UTC timestamps, and outcomes. The begin record uses the command
object's full name, bound arguments, and options regardless of the abbreviations
entered. `provided_arguments` identifies positional parameters supplied in the
command, which lets the audit distinguish a supplied value from the same default.
`display_deck_list`, `extract_deck`, and `expand_deck` also record the
resolved `snapshot` in their outcome, with its `version` and
`library_revision`. This includes the default snapshot and attempts that
fail after SCU resolves the snapshot.
`diff_deck` records its resolved labels as `from_deck_version` and
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
`verify_audit` (also `verify_audit_trail`) always scans the full chain and checks
recorded deck and header digests.

Run `show_history` to display the latest 20 audited command attempts in
chronological order, with canonical names, named parameters, and a
tab-separated status. `pending save` describes the state when the command
finished. A later save or discard is a separate audit event. Pass a count
as in `show_history 50` or `show_history number_of_lines=50`.
The displayed parameters can include sensitive values recorded in the audit log.

## Frontend integration

At startup the CLI loads and validates `commands.json` once. Command parsing,
Tab completion, and help use the same typed definitions. Parsing and completion
also share the tokenizer and argument binder. The CLI passes a read-only
`TScuCommand` to `TScuExecutor.Execute`. Other Free Pascal frontends can
construct the same object with canonical names, arguments in catalog order,
and named options.
They can implement `TScuOutput` to capture normal output and diagnostics.

The executor selects a command handler by canonical name and passes the same
command object to the audit logger. The executor owns locking and transaction
boundaries. Handlers resolve snapshot selectors and supply the resolved values
for the executor to record in the audit outcome.

## Historical reference

The NOS/VE manual documents `EXTRACT_DECK`, `EXPAND_DECK`, and selection
criteria for choosing decks. It also describes `INCLUDE_COPYING_DECKS` for
finding decks that include a changed common deck. This implementation's bulk
commands select decks by their stored version history.
[CDC NOS/VE Source Code Management, revision G, pp. 1-30–1-31](https://www.bitsavers.org/pdf/cdc/cyber/nos_ve/manuals/60464313G_NOS_VE_Source_Code_Management_198804.pdf)
