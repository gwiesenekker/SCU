# Source Code Utility user manual

SCU keeps the history of a project's source files in a SQLite library. A **deck** is one named file in that library. You can work in the SCU editor or keep editing ordinary files with vi or another editor. Both workflows save revisions to the same library.

## Start a project

Open a terminal in the directory that contains your source files. Create a library there and start an interactive session:

```sh
scu project.sqlite initialize_library
scu project.sqlite
```

At the `scu>` prompt, choose which files belong to the project and take the first snapshot. For a C project you might enter:

```text
configure_library file_patterns='["*.c","*.h","Makefile"]'
import_deck
display_deck_list
lock_version description="First working release"
```

Check the import summary before locking. Patterns select files directly beside the library. A later scan of the same patterns records new files, changed files, and deletions of previously tracked working files that have disappeared. An unchanged file keeps its deck version.

Successful modifications save automatically. Enter `quit` or press Ctrl+D at an empty prompt to leave. To open the same library in the GUI, run `scu-gui project.sqlite` or choose **File → Open library**.

## Edit, compare, and check in

Start the next version with `crev` after locking the current one. SCU suggests the next number from the library's version increment. You can also specify a label explicitly. Edit your working files and run the following commands at the SCU prompt as often as needed:

```text
impd
disvd
```

`impd` snapshots changes from disk. `disvd` compares the open library version with its locked predecessor. If you edit again, run `impd` again before comparing. By default the diff ignores changes in whitespace amount and legacy revision stamps such as `// SCU REVISION 8.1306`. The original source and line numbers are preserved. To review every textual change in unified format, use:

```text
disvd of=unified isc=no ilsh=no
```

Test your working files. When satisfied, enter `locv` at the SCU prompt or run `scu ln=project.sqlite locv` from the shell. Both open the configured external editor. Write a summary on the first line, then add as many paragraphs as needed. Use `disvh dd=full` to read the complete description below its version row, with the original paragraph breaks. Save the file and close the editor to lock the version. An empty description cancels the lock. In a shell script, supply it on the command line, for example `scu project.sqlite locv description="Fix board initialization"`.

Use `disl` to see whether the current version is locked or unlocked and inspect library settings, or `disl json=yes` for the full JSON header including version history.

## Understand versions and revisions

A library version groups changes across decks. Each deck has its own revision within that version. For example, `1.1-0.000` is the first stored revision of a deck in library version 1.1. An edit advances that deck's revision. A deck inherited unchanged from 1.0 can still show `1.0-0.000` when you view version 1.1. Deleting a deck preserves it in earlier snapshots.

| To answer this question | Command |
| --- | --- |
| Which decks changed in this version? | `disv` or `disv 1.1` |
| Which decks were present, including inherited ones? | `disdl version=1.1` |
| When and why was each version locked? | `disvh limit=0 display_description=full` |
| Which revisions exist for this deck? | `disd main.c` |
| What changed in its last edit? | `disdd main.c` |

Modification and lock times in `disd`, `disv`, and `disvh` use your local time zone. The numeric offset distinguishes the two occurrences of a local time when daylight saving ends. The JSON header, audit records, and release macros use UTC.

To undo an accidental `crev 8.1307`, enter `delv 8.1307`. This returns to the preceding locked version if 8.1307 is still open and has no deck revisions of its own. To remove a populated open version and its stored deck revisions, enter `delv 8.1307 delete_revisions=yes`. Earlier versions, audit history, and working files are preserved.

By default `disvh` shows the ten most recent versions. `disdd` compares the previous and current **stored revisions of one deck**. `disvd` compares **two library versions** across all decks.

## Use the GUI editor

Select a deck in the left pane to open its editor tab. A star beside the tab name means the buffer differs from stored source. Choose **Save deck** or press Ctrl+S to record your edit. If the library version is locked, choose **File → Create new version**, accept or edit the proposed number, then save the buffer.

The right pane compares the current stored deck revision with the live editor buffer as you type. Change either selector to compare another pair. `scu$live_deck_version` refers to unsaved editor text. `scu$current_deck_version` and `scu$previous_deck_version` refer to stored revisions. Selecting the previous revision is useful after saving an edit.

The bottom pane logs commands, results and build output. Right-click to copy text. Drag the splitters to resize the panes. Ctrl+Tab switches editor tabs and Ctrl+W closes the current tab. **Edit → Preferences** changes the editor font and library settings, including monitored file patterns and the build command.

Open this manual with **Help → Manual** or F1. Select a heading in the contents tree to jump to it. Press Ctrl+F to find text, F3 for the next match, Shift+F3 for the previous one, and Esc to return to the editor.

## Extract, build, and release

**Extract deck** writes one stored source file. **Extract version** writes working sources for the selected version. Both default to the library directory and run the configured build after successful extraction. To populate a fresh working directory with a complete current snapshot, including inherited decks, extract the current version:

```text
extv build=no
```

To discard an external edit to `book.c`, use `extd book.c o=y b=n`. SCU reports the output path and whether it wrote the file or found matching contents. If you already imported the edit, select the version to restore, for example `extd book.c v=8.1306 o=y b=n`.

Set `configure_library build_command="make"` to build after extraction. If no build command is set, extraction just writes the files. When SCU reports that an output contains local edits, import edits you want to keep before using `overwrite=yes`.

Choose **File → Publish version** or enter `relv` to prepare a complete release in the configured release directory (default `release`). Release expands uppercase macros such as `SCU$DECK_VERSION` and `SCU$VERSION`. `SCU$DATE`, `SCU$TIME`, and `SCU$DATE_TIME` use the deck's stored modification timestamp. The release command does not run a build or upload files. Review the resulting directory before publishing it.

## Verify exported files

Each export directory has a manifest tracking its exported files. `verd` checks the release directory by default. To check working exports instead, enter `verd output_directory=scu$library_directory`. Read the attention list to identify missing, locally changed, or outdated files.

## Audit trail

SCU keeps an audit trail inside each SQLite library. To see the latest 20 audited command attempts and their outcomes, enter `display_audit_trail` (`disat`). Use `disat 5` for the latest five. If you entered `disd dn=main.c`, the history shows the full command name `display_deck` and the argument name `deck_name`. The underlying records also identify the actor and UTC time.

A successful change and its audit records commit together. If the audit write fails, SQLite rolls back the library change. Commands that reach the audit log can also have a failed outcome. Help, input rejected by the parser, and the history and audit checks themselves do not add entries.

### Verify the library

Enter `verify_audit_trail` (`verat`) for a full check. SCU follows the SHA-256 chain and verifies the recorded digests for the library header and deck revisions. The result reports `records` (audit events, so one command can contribute several), `interrupted` (attempts with no recorded outcome), and `head` (the digest of the last event).

### Keep a checkpoint

After locking a release, run `verat` and save the 64-character value after `head=` somewhere independent of the library. To check a restored or shared copy later, enter `verat head=YOUR_SAVED_DIGEST` with that value.

Later commands may have added entries. Verification succeeds if the chain is valid and still contains your saved digest. A library rolled back to before the checkpoint, or a rewritten chain that changes the history through that point, fails this check. Without an independent checkpoint, an older, internally consistent copy can pass verification.

## Command and argument abbreviations

SCU names commands with a verb followed by one or more words separated by underscores. To form the NOS/VE abbreviation, take the **first three letters of the verb**, then the **first letter of each remaining word**. For example, `display_deck` becomes `disd`, `display_deck_list` becomes `disdl`, and `display_version_history` becomes `disvh`. Two commands also have familiar aliases: `help` lists commands and `quit` ends the session.

For an **argument**, use the first letter of **every** word. Thus `deck_name` becomes `dn`, `output_file` becomes `of`, and the single word `build` becomes `b`. The following commands all extract the same deck without running a build:

```text
extract_deck deck_name=main.c output_file=review.c build=no
extd dn=main.c of=review.c b=n
extd --dn main.c --of review.c --b n
extd main.c review.c b=no
```

Enter `disc extd` to see arguments in positional order, their abbreviations, types, and defaults. Enum values have their own listed aliases, such as `yes (y)` and `no (n)`. Quote strings containing spaces, for example `locv d="First working release"`.

## Recall and edit commands

At the `scu>` prompt, press **Up** to recall an earlier command and **Down** to move forward. History persists between sessions. Use the arrow keys to edit the recalled line, then press Enter to run it.

To find an older command, press **Ctrl+R** and type part of it, such as `main.c`. Press Ctrl+R again for an older match. **Enter** puts the selected command back at the prompt for editing. Press Enter again when ready to run it. **Ctrl+G** leaves the search and restores your draft.

To inspect what ran against the open library, enter `disat`. It reads the library audit trail and shows the expanded commands and their outcomes. The default is 20 entries; `disat 5` shows the five most recent.

## Complete commands with Tab

At the interactive prompt, type part of a command, argument, alias, or value and press **Tab**. For example, type `disv` and press Tab twice to see matching version commands, or type `extd dn=` and press Tab to complete a deck name. When several matches share a prefix, SCU fills in the shared part. A second Tab lists the matches in columns.

Suggestions follow the arguments already on the line. With `extd v=1.0 dn=`, completion offers decks visible in version 1.0, including inherited decks. After a deck is selected, revision suggestions belong to that deck. An argument supplied under its abbreviation is already used. SCU also completes enum values and file paths for arguments such as `source_file` and `output_file`.

If the matches fill the screen, **Space** or **Tab** advances one page and **Enter** advances one line. Press **Q** or **Esc** to return to your command with the draft intact.

## Batch input

A command file contains one SCU command per line. Enter `!commands.scu` at the prompt or redirect the file into the CLI from a shell. Batch execution stops at the first error by default. For example:

```sh
scu project.sqlite < commands.scu
```

## Command reference

Use the full command or any listed abbreviation. For argument details, enter `disc` followed by the command name.

| Command | Abbreviations | Purpose |
| --- | --- | --- |
| `configure_library` | conl | Set library configuration, editor, build command, release directory, or file patterns. |
| `create_deck` | cred | Create an empty deck or initialize it from a file. |
| `create_version` | crev | Create a higher version after locking the current version. |
| `delete_deck` | deld | Record the deletion of a deck in the open version. |
| `delete_version` | delv | Delete the current unlocked successor version. |
| `display_audit_trail` | disat | Show recent commands from the library audit trail. |
| `display_command` | disc | Show a command's help and its arguments and options. |
| `display_command_list` | discl, help | List commands alphabetically with aliases and short descriptions. |
| `display_deck` | disd | Show deck versions, local modification times, and stored/deleted status. |
| `display_deck_diff` | disdd | Compare stored deck source at two revisions or versions. |
| `display_deck_list` | disdl | List decks and their deck versions in the selected snapshot. |
| `display_library` | disl | Show the library summary and configuration in attribute/value columns. |
| `display_version` | disv | List decks changed in a library version. |
| `display_version_diff` | disvd | Compare source for all changed decks in two library versions. |
| `display_version_history` | disvh | Show versions, lock status, lock times, and descriptions. |
| `edit_deck` | edid | Edit an existing deck with the configured external editor. |
| `edit_file_patterns` | edifp | Edit the library file patterns, one wildcard or filename per line. |
| `extract_deck` | extd | Write the original source bytes to a file. |
| `extract_version` | extv | Extract the complete selected version and run the build. |
| `import_deck` | impd | Snapshot selected files or import one deck, creating, updating, or deleting revisions. |
| `initialize_library` | inil | Create an empty source library. |
| `lock_version` | locv | Lock the current version against further changes. |
| `quit_session` | quis, quit | Leave the interactive session. |
| `recover_library` | recl | Restore an SCU recovery file to a new SQLite library. |
| `release_version` | relv | Publish a complete version with release macros expanded. |
| `save_library` | savl | Confirm the library is saved. |
| `verify_audit_trail` | verat | Verify the audit chain and optionally check for a saved head. |
| `verify_decks` | verd | Verify tracked exports against the latest visible deck versions. |
