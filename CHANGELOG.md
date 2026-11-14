# Changelog

## Unreleased

- Fix review X13/X14: release cleanup keeps untracked matching files unless replace=yes, reports kept/removed names, and all exports use the selected revision's recorded filename and exact filename bytes.
- Fix L8/L9: support arbitrary root filenames through stable deck IDs; queue working-manifest observations in SQLite with import/audit transactions and replay them after interruption. Preserve source files and rollback semantics.
- Fix long manifest keys, skip identical file replacement, move private staging beside output with dead-process cleanup, and handle one-shot termination gracefully.
- Warn once for former COPY directives in release/verification. Breaking behavior: COPY remains literal and is never expanded.
- Make unified version diffs patchable with recorded filenames; retain bounded complete-replacement fallback for resource-intensive comparisons.
- Preserve invalid file-pattern edits for correction, explain kept files after deletion, reflow completion pages on resize, and correct the group-preservation test's replacement permission.
- Refactor command dispatch into a typed registration table, separate header/revision/names/query units and command snapshots, use named option sets/lock policies, and remove dead checkpoint and COPY-cache APIs while preserving legacy audited payloads.
- Document every open review finding as fixed, revalidated, or an explicit retained design decision in REVIEW_STATUS.md; add regression tests for data safety, observation replay/rollback, filenames, staging, patching, terminal behavior and edit recovery.

- Rename expand_version (expv) to release_version (relv), updating dispatch, completion, command help, documentation, and regression tests. Retired spellings report the replacement command.

- Separate source extraction/building from release publication. extract_deck and extract_version maintain raw-source manifests and run build_command (build=yes by default) from the library directory; extract_version retrieves the complete selected snapshot, including inheritance.
- Rename build_directory to release_directory, default release. Remove expand_deck and expansion checkpoint commands; expand_version always publishes the complete selected version without running builds.
- Remove COPY expansion and dependency tracking from active export/import paths. Expand only SCU$DATE, SCU$TIME, SCU$DATE_TIME, SCU$DECK_VERSION, and SCU$VERSION, preserving comment prefixes and all other source text. Date/time macros use stored deck modification times.
- Remove obsolete regular release files matching file_patterns only when absent from the selected snapshot. Preserve unrelated files, directories, links, SQLite storage, and edited tracked files unless replacement is explicit.
- Journal release deletions with batch writes and reconcile interrupted cleanup without deleting externally recreated files. Retain legacy audited payload bytes and manifest compatibility.
- Replace tests for retired COPY/incremental expansion behavior with full release, deterministic macro, extraction build, cleanup, and interruption regressions; update command help and README workflows.

- Extract decks under their original filenames without an added .scu suffix; keep raw sources beside the library and published sources in the release directory. Allow unchanged source files to be tracked without replacement, protect differing files unless replace=yes, and treat .scu as an ordinary source extension during scans.

- Preserve the selected library in nested SCU build calls.
- Rename extract_modified_decks/extmd to extract_version/extv; use original filenames in the library directory.
- Batch export recovery intents and manifest completion, index file records, and share rendering across export and verification. Preserve exact path bytes and legacy manifest recovery.
- Protect differing edited/untracked output with replace=yes, prevent release output over working sources or SQLite databases, and refuse importing tracked generated files.
- Track explicit source associations, preserve unmanaged decks during snapshots, reject empty snapshot selectors and symlink imports, and skip SQLite companions.
- Recover hot SQLite journals for logical readers; clarify transaction rollback and audit-attempt semantics.
- Stop CLI command files at EOF, support comment lines, improve unknown-argument diagnostics, preserve cancellation as a separate exception, and show build failures in command history.

- Normalize library names consistently for positional, named, and backend use: append .sqlite when no extension is given and reject all other extensions without opening or creating files.
- Recognize extensionless positional library names before any known command, including startup batch arguments, while retaining command-name precedence and lone-unknown-command diagnostics.
- Apply the same extension rule to archive-import destinations and document creation and interactive naming behavior; add CLI, backend, and importer regressions.

- Restrict import_deck snapshots and file_patterns to files directly beside the library; reject directory components in source_file and file_patterns, deferring subdirectory support to a future library option.
- Resolve source_file in the library directory, complete only filenames there, and stage archive-import source files beside its temporary library.
- Keep earlier subdirectory selections readable for correction while refusing to scan them; add directory-scope, filename-validation, completion, and compatibility regressions.

- Merge store_deck into import_deck (impd): import a named deck from an optional source file, or omit the deck to snapshot file_patterns in the library directory.
- Snapshot new, changed, and missing files transactionally, preserving unchanged inherited decks and historical source through deletion/recreation revisions; report deck versions and new/changed/deleted statuses with summary counts.
- Record source filenames in new revision payloads for reliable case-sensitive deletion tracking; retain older payload bytes and defaults, reject basename collisions and selected symlinks, and exclude SQLite operational files and the export manifest.
- Update the archive importer, command catalog/help, and regressions for the merged command, snapshot selection, and whole-batch rollback on revision or audit failures.

- Add the library-wide file_patterns list and edit_file_patterns (edifp), opening one wildcard or filename per line in the configured editor and saving the result transactionally.
- Show file_patterns in display_library; default to an empty list for older libraries without rewriting audited header bytes.
- Reuse the deck editor's process handling and private temporary-file cleanup; validate library-relative entries, support GUI editor wait arguments, and add regressions for persistence, no-op/empty edits, editor failures, cancellation, audit rollback, and legacy headers.

- Add quit as a convenience alias for quit_session, alongside quis.

- List extracted deck names and resolved deck versions in extract_modified_decks, using the same aligned columns as expand_version; add regression coverage.

- Save every successful modifying command automatically, committing deck revisions, library metadata, and audit records together through SQLite's journaled transactions.
- Remove the save_library argument and discard-on-quit behavior from quit_session; retain save_library as a saved-state confirmation.
- Allow interactive edit/import followed immediately by expand_version, with no manual save step; reload committed state between commands to preserve concurrent updates.
- Recover interrupted transactions through SQLite's rollback journal; discard failed commands' in-memory state and retain support for reading older recovery JSON files.
- Add regressions for immediate persistence, quit and termination, concurrent sessions, audit-write rollback, expansion checkpoints, and crashes immediately before/after commit.

- Wrap version-history descriptions before other columns so UTC lock timestamps remain intact; use labelled fields on narrow terminals and preserve whole values when they fit.
- End successful verify_decks runs with "No errors were found." alongside the checked-file count and selected version.

- End verify_decks with a needs-attention list naming every affected deck, file, and full reason; omit current files and wrap explanations to terminal width.
- Continue verification after per-file read/type errors so the final report includes other decks as well.

- Compact verify_decks columns and move verbose diagnostics and custom filename mappings below the table, preventing long errors from squeezing every filename.
- Sort tracked verification rows by filename and report deleted decks explicitly, retaining export records and files for obsolete-output detection and historical verification.

- Skip dot-prefixed source files and hidden directory trees during archive imports, excluding them from manifests, filename mappings, counts, and deletions.

- Rename expand_modified_decks (expmd) to expand_version (expv), retaining expand_deck (expd) for a single deck.
- Keep scu$current_version as the incremental default; add scu$latest_version for full checkouts of all live decks, including inherited decks, independently of checkpoints.
- Invalidate checkpoints before a full checkout, preserve failed-build retry state, and retain historical build information from the former command name.
- List actual deck names and deck versions when expanding a version, with terminal-width wrapping and normal recoverable manifest updates.
- Default extract_modified_decks output_directory to scu$library_directory so extmd runs without arguments or prompts.

- Journal export intents inside .scu-exports.json before replacing files; automatically complete or discard interrupted updates by checksum on the next export or verification.
- Preserve externally changed files as interrupted export records requiring explicit re-export, including interrupted retries; retain partial batch tracking without advancing build checkpoints.
- Add crash-injection regressions for first and replacement exports, recovery retries, conflicting edits, partial batches, and invalid recovery records.
- Default extract_modified_decks (extmd) to scu$current_version without prompting, while retaining explicit version selection.

- Default extract_deck to <deck_name>.scu and use .scu filenames for extract_modified_decks, preserving the default expanded files; explicit output_file paths remain unchanged.
- Add import_deck (impd) to import any source filename into an existing deck as a new revision, preserving its comment prefix unless overridden.

- Make revision a per-deck revision identifier (0.000–0.999) within a selected library version; allow version and revision together for extraction and expansion, with complete deck-version shorthand.
- Default snapshot selectors to scu$current_version; resolve COPY against the selected version while allowing an older root revision, and audit the resolved root deck version.
- Remove internal library revision selectors from display_deck_list and hide snapshot boundaries in list_versions; align help, completion, errors, and current/previous version handling across commands.
- Add verify_decks (verd) with atomic per-directory .scu-exports.json tracking, recursive COPY verification, reproducible expansion-time macros, and statuses for outdated, edited, missing, unavailable, and untracked exports.

- Import unchanged files through inheritance after exact byte comparison with the preceding snapshot; retain full manifests and correctly recreate deleted files.
- Wrap long deck names and other table cells to terminal width, preserve aligned continuation lines, and stack fields on very narrow terminals; retain unwrapped redirected output.
- Standardize on scu$current_version, replacing scu$current_library_version in bulk expansion defaults and supporting completion of the canonical selector.
- Include the resolved root deck name in extract_deck and expand_deck snapshot reports.

- Add display_version (disv) to list each deck changed in a library version, defaulting to scu$current_version, including deletions and pending edits while omitting unchanged inherited decks.

- Rename start_version to create_version (crev); update command handling, the archive importer, help, and examples.

- Identify the resolved deck name above the display_deck history table, including when using the last-modified-deck default.

- Add display_deck limit (l), default 10 newest entries; use 0 for the complete history.
- Move the selected current and previous locked versions into the display_library attribute/value table; keep only the path on its opening line.
- Align list_versions, expansion checkpoints, and show_history with headers and two-space column separators.

- Show display_deck_list in aligned Deck name and Deck version columns with two-space separators and headers, including for empty snapshots.

- Unify command parameters into one ordered argument list (catalog format 4), accepting positional, name=value, and --name value forms; use the same named arguments in execution and auditing.
- Add aligned display_deck headers for deck version, UTC modification time, and stored/deleted status; omit the internal library revision number.
- Keep only standard NOS/VE command abbreviations, with help as the sole additional command alias.

- Accept positional description mode and limit in display_version_history (for example, disvh short 0) while retaining named forms; support long named forms for positional arguments in parsing and completion.

- Default display_version_history to the 10 most recent versions, including the current version; add integer limit (l), with 0 selecting all history.

- Show display_library configuration in aligned attribute/value columns without version history; show current and previous locked versions in its attribute/value table and retain full JSON through show_library.
- Align display_version_history columns using spaces with two-space separators instead of tabs.
- Add enum value aliases with canonical names passed to the backend and audit trail; replace Boolean command parameters with yes/no enums and y/n aliases.

- Add enum arguments and options with catalog-defined allowed values, case-insensitive validation, help and prompt choices, and Tab completion; use enum for diff output_format.
- Default display_version_history to the first description line and add display_description=short|full (dd) to select the description detail.

- Default deck and version diffs to normal output with changed lines only; retain unified output through output_format=unified (of=unified).

- Default deck and version diffs to diff -b whitespace comparison, with ignore_space_changes=no for exact comparison and original source retained in diff output.

- Report the selected library version and resolved root deck_version after extraction and expansion, including inherited and pending deck revisions.

- Add a Python directory-archive importer with numeric version ordering, multiline HISTORY descriptions, deletion and recreation, filename manifests, dry runs, and publication after audit verification.
- Allow initialize_library to select its initial version with version=, retaining 1.0 as the default.

- Add delete_deck (deld) with audited deletion revisions, historical source retention, and recreation through create_deck or store_deck.
- Respect deletions in snapshots, diffs, completion, recovery, and incremental expansion; index deletion flags without rewriting existing audit-covered payloads.

- Stop command batches on the first error by default, support continue_on_error, and read nested SCU command files with !.

- Document the NOS/VE command abbreviation convention and check every command's verb and standard abbreviation in the catalog regression tests.
- Enforce lazy revision guards in normal builds and mark only library-changing commands as pending save.
- Keep background terminal reads alive when job-control signals are ignored, resume stopped background builds with fg, and finish interrupted prompts with a newline.
- Add display_version_diff with previous/current library version defaults and inherited, added, and removed deck comparisons.
- Rename the deck diff command to display_deck_diff with disdd as its alias.
- Extract unescaped deck base64 before parsing revision metadata, with JSON fallback for escaped spellings and compatible audit serialization.
- Require a description when locking a version, record its UTC lock timestamp, and add display_version_history.
- Validate catalog commands in the CLI and retain successful outcomes when Ctrl+C arrives after commit.
- Split executor transaction phases and completion providers into focused routines.
- Keep the shell in control after background builds and save pending edits on termination from the pager or a suspended prompt.
- Reject unsupported catalog commands at startup and prevent recursive builds.
- Decode deck base64 directly and expand source lines without copying each line.
- Test the diff edit limit and add context to deck payload and output directory errors.
- Show audit history outcomes without taking the library lock and record resolved output destinations for extraction and expansion.
- Support extensionless library paths, retain output file groups, remove dangling editor links, and report broken output pipes accurately.
- Suspend and resume interactive builds and completion paging through shell job control.
- Keep interactive history and completion snapshots session-local, and make storage constructors and file options explicit.
- Use OpenSSL for deck checksums and avoid re-encoding decoded base64 payloads.
- Reduce the memory used by the bounded diff search and test its fallback patch.
- Manage the terminal signal mask, signal descriptor, and editing settings in one session object.
- Separate build and editor process handling from session signal handling.
- Separate shared errors, file operations, and locks into dedicated units.
- Separate SQLite connection and schema management, revision and audit storage, and checkpoint display formatting.
- Use named SQLite open factories to start transactions and check schemas consistently.
- Identify the affected setting, file, or operation in JSON, filesystem, and conversion errors while preserving Ctrl+C cancellation.
- Use typed library headers, versions, and revision entries with stable ownership and audit-compatible serialization.
- Load and validate the command catalog at startup and share typed definitions across parsing, completion, and help.
- Share tokenization and argument binding between command parsing and Tab completion, and render help in a dedicated unit.
- Split library commands into handlers while the executor manages locks, transactions, and the audit trail.
- Serialize parallel expansions in the same directory and let builds invoke nested single-deck expansion there.
- Cancel library lock waits on Ctrl+C before the command runs, and report nested COPY cancellation once.
- Add `recover_library` to restore full or pending-only recovery files into a new SQLite library.
- Scan past ordinary source bytes and compare macro tokens in place during expansion.
- Persist the audit head and count in SQLite to keep routine audit appends fast as history grows.
- Use per-revision COPY metadata to find incremental build dependencies without decoding unrelated decks.
- Add `show_history` to display the latest 20 canonical audited commands or a supplied line count.
- Separate command parsing from library execution and audit the same canonical command object that the executor receives.
- Use SQLite for all live libraries and audit records. Remove the legacy JSON backend and its migration commands.
- Add deck and library version macros and separate UTC modification and expansion macros.
- Keep empty named arguments separate from following values to protect output files.
- Save or recover pending changes on SIGTERM and SIGQUIT, give interactive builds the terminal, and retain successful editor saves after Ctrl+C.
- Add `verify_audit_trail` as an alias for `verify_audit`.
- Reuse verified audit state within a session to keep command scripts fast as the log grows.
- Default extract and expand destinations to the selected deck, respect explicit empty arguments, and accept `--option=value`.
- Preserve unsaved edits across interrupted builds and terminal hangups, with a recovery file when a hangup save fails.
- Isolate build input, serialize expansion output directories, and resolve bare editor names through PATH.
- Authenticate newly saved deck payloads and library headers in the audit log, and add repair for an incomplete JSON audit tail.
- Load SQLite deck payloads on demand and preserve more context in large scattered diffs.
- Preserve source output permissions, order new versions as decimals, and skip identical stores within the same version.

- Added the Free Pascal SCU command line and JSON command definitions.
- Added a JSON deck library with zstd compression, base64 encoding, and SHA-1 verification.
- Added SQLite libraries with one JSON payload per deck revision, transactional saves and audit records, and JSON import and export.
- Default to `library.sqlite`, with a fallback to an existing `library.json`.
- Added integration tests for SQLite import and export and for rolling back both library changes and audit records when writing a save outcome fails.
- Added SQLite checkpoints for `expand_version` by version and output directory. Expand changed decks and their transitive COPY dependents, and advance the checkpoint with the successful build audit record.
- Advance the SQLite checkpoint after a successful expansion when no build command is configured, and show the checkpoint revision separately from the last actual build.
- Default `expand_version` to the current library version and the directory containing the library without prompting.
- Added `display_expansion_checkpoints` (`disec`) to list the last successfully built library revision for each SQLite checkpoint.
- Added `reset_expansion_checkpoint` (`resec`) to force a full rebuild for a SQLite version and output directory.
- Show pending full rebuilds alongside the last successfully built revision in `display_expansion_checkpoints`.
- Show the last successful build time in UTC in `display_expansion_checkpoints`, using the existing audit history.
- Show the library version before the per-deck revision in deck write confirmations and omit SHA-1 from the confirmation.
- Report the current library version when `edit_deck` cannot find a deck.
- Report the selected version in missing-deck errors from `extract_deck` and `expand_deck` unless a library revision was specified.
- Added library-wide revisions, version locking, and named version snapshots.
- Added a library header with version history, comment prefixes, and external editor configuration.
- Added deck editing, exact extraction, and expansion of nested COPY directives and the stored modification date, time, and version macros.
- Added `create_deck` with optional `from_file` for creating empty decks or importing their initial source.
- Stored comment prefixes per deck revision so a library can expand decks with different directive syntax.
- Added bulk extraction and expansion of decks changed in a version.
- Added deck revision history and unified diffs by revision or version.
- Added the `last_modified_deck` library attribute and made it the default for `display_deck` and `diff_deck`.
- Default `extract_deck` and `edit_deck` to `scu$last_modified_deck`.
- Default the output filename of `extract_deck` to `scu$last_modified_deck` without prompting.
- Default the deck name and output filename of `expand_deck` to `scu$last_modified_deck` without prompting.
- Generate unified deck diffs in Free Pascal without GNU `diff` or temporary files.
- Added JSON-defined command and argument abbreviations with canonical audit entries.
- Organized command definitions with typed, command-specific arguments and options, including descriptive names such as `source_file` and `output_file`.
- Added library-first invocation, `ln=` selection, and interactive sessions.
- Added `save_library` and Boolean `quit save_library=` to save or discard interactive changes.
- Added `display_library` to show the selected library's current snapshot when opening an interactive terminal session.
- Show the current and previous locked library versions in `display_library` and the startup banner.
- Show the full library configuration in `display_library`, including the editor and build command.
- Added a brief command list, detailed per-command help, and required argument prompts with Ctrl+C cancellation.
- Use NOS/VE-style parameter signatures in detailed help and interactive prompts.
- List the full command name and aliases together at the top of detailed help.
- Sorted the command list and `commands.json` alphabetically by full command name.
- Aligned command descriptions using the longest full name in the command list.
- Show comma-separated aliases in the command list and align descriptions after the longest entry.
- Wrap command descriptions to the terminal width and align their continuation lines.
- Wrap detailed help and parameter descriptions to the terminal width while preserving indentation.
- Wrap interactive parameter prompts to the terminal width while preserving description indentation.
- Sorted each command's options in `commands.json` alphabetically by full option name.
- Sorted command, argument, and option aliases alphabetically in `commands.json`.
- Added a test for alphabetical catalog order that allows positional arguments to follow parsing order.
- Added `make format-commands` to sort commands, options, and aliases while preserving positional argument order.
- Added required and optional argument rules and defaults in command definitions.
- Added short argument and option descriptions to detailed command help.
- Show argument descriptions, expected types, and aliases at interactive prompts.
- Added Enter-to-accept defaults and in-session command history editing.
- Saved terminal command history across sessions in the user's state directory.
- Standardized full command names and added abbreviations while keeping existing spellings as aliases.
- Added interactive Tab completion for command names, arguments, options, and aliases.
- Display Tab completion matches in aligned columns that fit the terminal width.
- Page long Tab completion lists without losing the draft command or cursor position.
- Replaced GNU Readline with a Free Pascal terminal editor that supports editing, persistent history, Tab completion, and Ctrl+C cancellation.
- Added Ctrl+R to search saved command history backward and recall a match for editing.
- Added value completion from the current library and filesystem, including at argument prompts.
- Filtered deck completion by the selected snapshot and revision completion by the selected deck.
- Filtered version completion to versions that contain or inherit the selected deck.
- Hid supplied arguments and options from Tab suggestions, including their aliases.
- Hid mutually exclusive options and their aliases from Tab suggestions.
- Listed mutually exclusive option groups in detailed command help.
- Added named-version, library-revision, and default snapshot examples to detailed command help.
- Reported the version and library revision used for deck listing, extraction, and expansion.
- Recorded resolved snapshots in audit outcomes for deck listing, extraction, and expansion.
- Reported and audited both resolved endpoints for deck comparisons.
- Added version, revision, and mixed-selector examples to `diff_deck` help.
- Added `scu$current` as a selector for either `diff_deck` endpoint.
- Made `diff_deck` use `scu$current` automatically when `to_snapshot` is omitted, including in interactive mode.
- Added `scu$previous` to compare against the most recent locked version before the current version.
- Made `diff_deck` use `scu$previous` automatically when `from_snapshot` is omitted.
- Made the omitted `diff_deck` baseline fall back to the deck's prior revision when there is no earlier locked version.
- Added per-deck revision numbering, deck versions, and configurable version and revision increments. Diff defaults now follow the selected deck's history across library versions.
- Show deck versions in `display_deck_list`.
- Show resolved deck versions in `diff_deck` reports and patch labels.
- Renamed the diff selectors to `scu$current_deck_version` and `scu$previous_deck_version` and limited comparisons to deck versions.
- Added `build_command` and the `build` option on single and bulk expansion.
- Reported a missing library before trying to open its audit log.
- Unified required, optional, and default argument rules under `value` in command definitions.
- Added SHA-256 audit chaining with saved-head verification.
- Added integration tests for version snapshots, editor behavior, corruption detection, and concurrent stores.
