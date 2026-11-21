# Source Code Utility user manual

SCU keeps the history of a project's source files in a SQLite library. A **deck** is one named file in that library. You can work in the SCU editor or keep editing ordinary files with vi or another editor. Both workflows save revisions to the same library.

## Start a project

Open a terminal in the directory that contains your source files. Create a library there and start an interactive session:

```sh
scu project.sqlite initialize_library
scu project.sqlite
```

The library summary shows the OS that created the library. When opening a
library from another OS, check the warnings below the summary for decks whose
output filenames could collide or be invalid. Run `disl` to repeat the check.
An older library with no recorded platform shows `unknown`. To record its creation OS once, run `conl platform=Linux`, substituting `Windows` or `macOS` as appropriate. This also works on a locked version.

At the `scu>` prompt, choose which files belong to the project and take the first snapshot. For a C project you might enter:

```text
configure_library file_patterns='["*.c","*.h","Makefile"]'
import_deck
display_deck_list
lock_version description="First working release"
```

Check the import summary before locking. Patterns select files directly beside the library. A later scan of the same patterns records new files, changed files, and deletions of previously tracked working files that have disappeared. An unchanged file keeps its deck version. Each deck needs a distinct working filename on the host. For patterns shared across Linux and Windows, use bracket ranges such as `[a-z]`. Windows folds filename case and rejects POSIX named classes such as `[[:alpha:]]`.

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

Deleting revisions can leave a working file as the only copy of its contents. The next extraction reports a conflict if it would replace those bytes. Inspect or copy the file before using `overwrite=yes`. This protection also applies to alternate output directories and reused version numbers.

Use `disl` to see whether the current version is locked or unlocked and inspect library settings, or `disl json=yes` for the full JSON header including version history.

## Understand versions and revisions

After `crev` saves the new version, SCU refreshes the configured tracker beside the library. For example, `crev 8.1309` updates a generated `version.h` to show `8.1309`. It preserves hand edits and reports the conflict. This also applies when SCU chooses the next version using `version_increment`.

To correct the current unlocked version name, enter `renv 8.132 8.1308` (after version 8.1307). This keeps each deck’s revision number and contents. An inherited deck retains its original deck version. SCU refreshes the configured working version tracker after saving the rename. It preserves a hand-edited tracker and reports the conflict. Earlier audit entries and existing release files retain their historical names.

A library version groups changes across decks. Each deck has its own revision within that version. For example, `1.1-0.000` is the first stored revision of a deck in library version 1.1. An edit advances that deck's revision. A deck inherited unchanged from 1.0 can still show `1.0-0.000` when you view version 1.1. Deleting a deck preserves it in earlier snapshots.

| To answer this question | Command |
| --- | --- |
| Which decks changed in this version? | `disv` or `disv 1.1` |
| Which decks were present, including inherited ones? | `disdl version=1.1` |
| When and why was each version locked? | `disvh limit=0 display_description=full` |
| Which revisions exist for this deck? | `disd main.c` |
| What changed in its last edit? | `disdd main.c` |

Modification and lock times in `disd`, `disv`, and `disvh` use your local time zone. The numeric offset distinguishes the two occurrences of a local time when daylight saving ends. The JSON header, audit records, and release macros use UTC.

Set the library version step with `conl vi=0.001`. After locking version `8.1307`, running `crev` then creates `8.1317`. For `8.1308` as the next version, use `vi=0.0001`. The default step is `0.01`. SCU accepts up to ten fractional digits.

If you locked the current version too soon, enter `unlv`. It takes no arguments.
You can then import further edits into that version and use `locv` again with a new description.
The audit trail retains the earlier lock. Once a successor exists, the earlier version stays locked.

`disvd` ends with a per-deck line summary and totals. Within each replacement block it pairs old and new lines as changed and counts the excess as added or deleted. Binary differences are listed with dashes for line counts. With `of=unified`, SCU omits the summary and version announcements so standard output contains the diff and standard error is reserved for errors.

To undo an accidental `crev 8.1307`, enter `delv 8.1307`. This returns to the preceding locked version if 8.1307 is still open and has no deck revisions of its own. To remove a populated open version and its stored deck revisions, enter `delv 8.1307 delete_revisions=yes`. Earlier versions, audit history, and working files are preserved.

Deck names are case-sensitive. Use the spelling shown by `disdl`. Scanning or importing a new file named `Makefile` uses `Makefile` as its deck name. Command and argument abbreviations still accept either case.

The archive importer strips one leading `// SCU REVISION` header before storing a deck. Extraction returns the remaining bytes. Archive imports attach their original file lists, checksums, filename mappings and HISTORY entries to each locked version. Use `disl json=yes` to read the version’s `import_manifest`. The import manifest describes the original archive and stays in the version metadata on unlock. Supply a new `import_manifest_file` when relocking to replace it.

By default `disvh` shows the ten most recent versions. `disdd` compares the previous and current **stored revisions of one deck**. `disvd` compares **two library versions** across all decks.

Run `scu --version` from the shell or choose **Help → About SCU** to see the application release number and abbreviated Git commit ID as a single string. This works before opening a library.

## Use the GUI editor

Select a deck in the left pane to open its editor tab. A star beside the tab name means the buffer differs from stored source. Choose **Save deck** or press Ctrl+S to record your edit. Choose **File → Lock version** to lock the saved revisions. The dialog shows the current version above the multiline description. **File → Unlock version** reopens that version for editing. To start a new version after locking, choose **File → Create new version**, accept or edit the proposed number, then save the buffer.

The right pane compares the current stored deck revision with the live editor buffer as you type. Change either selector to compare another pair. `scu$live_deck_version` refers to unsaved editor text. `scu$current_deck_version` and `scu$previous_deck_version` refer to stored revisions. Selecting the previous revision is useful after saving an edit.

The bottom pane logs commands, results and build output. Right-click to copy text. Drag the splitters to resize the panes. Ctrl+Tab switches editor tabs and Ctrl+W closes the current tab. **Edit → Preferences** changes the editor font and library settings, including monitored file patterns and the build command.

Open this manual with **Help → Manual** or F1. Select a heading in the contents tree to jump to it. Press Ctrl+F to find text, F3 for the next match, Shift+F3 for the previous one, and Esc to return to the editor.

### Edit file patterns and the version tracker

Open the library, then choose **Edit → Preferences**. The **File patterns** tab controls which working files `import_deck` (`impd`) scans in the library directory. Enter one wildcard or exact filename per line, for example:

```text
*.c
*.h
Makefile
```

On the **Version tracker** tab, enter `version.h` as the output filename. The text box below it holds the template. You can use the supplied C header or edit it, for example:

```c
#ifndef VERSION_H
#define VERSION_H
#define PROJECT_VERSION "SCU$VERSION"
#endif
```

Choose **OK** to save the settings together. **Cancel** discards the edits. In the CLI, `edifp` edits the file patterns, `conl vt=version.h` sets the tracker filename, and `edivt` opens its template in the configured editor. To load an existing template from disk, use `conl vt=version.h tracker_template_file=version.h.in`.

For example, `extv v=8.1307 b=n` writes a header containing `#define PROJECT_VERSION "8.1307"` and reports `version.h has been expanded`. A single-deck extraction such as `extd book.c` also generates the header beside its output. Publishing with `relv` generates it in the release directory. If the header already matches, these commands report `version.h is unchanged` and preserve its modification time.

After a successful `impd`, SCU refreshes the version tracker in the library directory for the current version. This works for pattern scans and single-file imports, even when no decks changed. SCU reports whether the tracker was expanded or is unchanged. SCU can replace a working tracker that matches the current template rendered for an earlier library version. If it cannot recognize the bytes, it keeps the file and reports the conflict. To replace it explicitly, use `extd version.h o=y b=n`. Importing does not run the build.

Although `*.h` matches `version.h`, a working-file scan reports `version.h has been ignored (version tracker)`. Verification also skips the generated file. Edit the template in Preferences or with `edivt` to keep changes. If you edited the generated header directly, extraction requires `overwrite=yes` to replace it.

The template belongs to the whole library. Extracting an older version uses today's stored template with the selected version number. The date and time macros use the template’s last modification time in UTC. The tracker has no deck version of its own. To stop generating it, clear the filename in Preferences or enter `conl vt=`. The template stays in the library.

## Extract, build, and release

**Extract deck** writes one stored source file. **Extract version** writes working sources for the selected version. Both default to the library directory and run the configured build after successful extraction. To populate a fresh working directory with a complete current snapshot, including inherited decks, extract the current version:

```text
extv build=no
```

`extv` reports `Matches` when the working file already contains the exact bytes of the selected deck revision. The summary counts these files separately, for example `Wrote 0 deck(s) for version 8.132, Matches: 93`.

Both `extd` and `extv` can replace a working file if its contents exactly match any surviving revision of the same deck. This includes an old revision you deliberately restored by hand. When `extv` encounters working files that match no such revision, it lists their deck names, versions, conflict statuses, and output filenames. The batch stops before extraction and the build. Review the list before using `extv o=y` to replace those files.

To discard an external edit to `book.c`, use `extd book.c o=y b=n`. SCU reports the output path and whether it wrote the file or found matching contents. If you already imported the edit, select the version to restore, for example `extd book.c v=8.1306 b=n`.

Set `configure_library build_command="make"` to build after extraction. If no build command is set, extraction just writes the files. When SCU reports that an output contains local edits, import edits you want to keep before using `overwrite=yes`.

Choose **File → Publish version** or enter `relv` to prepare a complete release in the configured release directory (default `release`). Release expands uppercase macros such as `SCU$DECK_VERSION` and `SCU$VERSION`. `SCU$DATE`, `SCU$TIME`, and `SCU$DATE_TIME` use the deck's stored modification timestamp. The release command does not run a build or upload files. Review the resulting directory before publishing it.

## Verify exported files

Run `verd` to compare working files beside the library directly with the current version, or `verd v=1.1` to compare with another version. SCU checks each live deck at its recorded filename. The `Deck version` column shows the revision used for comparison. The status is `matches` when the file is byte-for-byte identical to that revision. Extra files and the configured tracker are ignored. Custom filenames supplied to `extd` are not remembered. Working directories need no manifest. For published files, use `verd od=scu$release_directory` or name the release output directory. Its hidden manifest is normally `release/.scu-exports.json`.

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
| `edit_version_tracker` | edivt | Edit the library-wide template for the generated version file. |
| `extract_deck` | extd | Write the original source bytes to a file. |
| `extract_version` | extv | Extract the complete selected version and run the build. |
| `import_deck` | impd | Snapshot selected files or import one deck, creating, updating, or deleting revisions. |
| `initialize_library` | inil | Create an empty source library. |
| `lock_version` | locv | Lock the current version against further changes. |
| `quit_session` | quis, quit | Leave the interactive session. |
| `recover_library` | recl | Restore an SCU recovery file to a new SQLite library. |
| `release_version` | relv | Publish a complete version with release macros expanded. |
| `rename_version` | renv | Rename the current unlocked library version. |
| `save_library` | savl | Confirm the library is saved. |
| `unlock_version` | unlv | Reopen the current locked version for editing. |
| `verify_audit_trail` | verat | Verify the audit chain and optionally check for a saved head. |
| `verify_decks` | verd | Compare working files or a published release with a library version. |
