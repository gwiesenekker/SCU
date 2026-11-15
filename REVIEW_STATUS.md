# Current review status

The current disposition covers Claude's review of **5d70945** and all earlier
findings. **No implementation fixes from that review are deferred.** Old imported
archives still require the explicit rebuild described below; audited revisions
are never rewritten. Earlier sections contain supporting detail, and their
validation counts are explicitly historical.

| ID | Current disposition | Reason or change |
| --- | --- | --- |
| X21 | Fixed | Check every stored revision of the import-manifest deck, rather than only its live snapshot. Old provenance remains effective after deletion, recreation, or replacement. Check only that deck's metadata; decompress only candidates with the old recorded filename. Regression tests cover deletion, recreation, a single remaining numeric deck, default/bulk exports, verification, unified diff, explicit-file rescue and intact audited revisions. |
| X20 | Fixed | Open cleanup candidates and `.owner` markers with `O_RDONLY`, retaining no-follow, ownership/type checks and nonblocking exclusive flock. Read-only stale files can be unlinked using directory permissions. Regression covers 0444/0644 atomic temporaries and a 0400 ownership marker. |
| X18 | Guarded; rebuild required | The library-wide history guard prevents unsafe default filenames. Named import without `source_file` now gives the same rebuild instruction. Explicit source-file import and literal output-file extraction remain available for rescue. Rebuild old archives into a new database, preserving any later edits separately. Ordinary numeric filenames without old provenance remain valid. |
| X19 | Fixed; real-process test added | In addition to simulated lock owners, pause a real SCU after staging, confirm its `.owner` cannot be locked by another process, start a concurrent release, and verify it waits without deleting the live stage. Kill the first SCU and confirm the waiting release cleans the stale stage, completes publication and passes audit/manifest verification. |
| Filename notices | Fixed where needed | The delete working-file notice now JSON-escapes line breaks. Release kept/removed notices already did so; the regression verifies both. |
| D3 | Closed, documented contract | Headers use recorded filenames in both comparison modes. Exact textual patch applicability requires `ignore_space_changes=no`; the default remains the requested whitespace-insensitive review mode. |
| D1 | Retained design | Bounded diff search prevents pathological memory/time use; fallback emits a complete replacement. |
| M5 | Retained design | Typed owners retain canonical JSON to preserve existing audit digests and unknown extensions. |
| M11, M17 | Retained design | Further naming/property changes and arbitrary routine-length limits are style preferences, not identified correctness defects. Responsibility splits already made remain in place. |
| M24, M25 | Retained design | Keep explicit typed SQL ownership and coherent reader state instead of introducing generic wrappers or a second input-source hierarchy. |
| P20, P21 | Retained behavior | Recoverable editor files are retained for rescue; last_modified_deck literally includes deletions and reports them explicitly. Neither behavior silently discards/substitutes user work. |

Other recommendations: README examples now use `ARCHIVE`, the X15 summary uses
lock-based cleanup, and historical test counts are labeled by the fixes they
validated. Claude Desktop's failing shell is an external application/environment
issue; it is not an SCU defect and is not changed here. This workspace's shell,
build, crash-injection and process tests are available and exercised.

Validation: `make test` passed with 276 tests run: 275 passed and one skipped
because this host has no second writable group. Five new regressions cover the
changes above. The executor probe and catalog checks passed; `git diff --check`
also passed.

---

# Disposition of Claude's review of b2688d9

Claude's reading-only review correctly identified additional workflow edges. The
findings below have been checked against the full checkout; the original review
is unchanged. Earlier dispositions follow below.

| ID | Disposition | Change or reason |
| --- | --- | --- |
| X18 | Guarded; rebuild required for old archives | Detect the old importer's provenance manifest and refuse default/bulk exports, verification and unified version patches before temporary names can be published. Ordinary numeric source filenames are valid. Rebuild from the archive into a new database using the current importer; the regression reproduces inherited duplicate numeric associations, checks refusal leaves revisions intact, and rebuilds/releases a replacement. No audited revision is rewritten and no filename is guessed. Later edits unique to the old library must be rescued before switching; single-deck extraction with an explicit literal output filename remains available and is tested. |
| L10 | Fixed | A POSIX source-filename validator is separate from pattern syntax. It rejects empty/dot names, slash, NUL and the reserved manifest name, naming the offending file. Backslash, colon, newline and carriage return remain valid bytes, with scan/export/replay round-trip tests. Pattern configuration still uses single lines and has its own restrictions. |
| D3 | Clarified contract | Exact textual unified patches require `ignore_space_changes=no`. Keep the requested `diff -b` default for review; help and README now state that `output_format=unified` alone cannot guarantee target bytes. The existing multi-file patch-application regression uses exact comparison. Binary/empty-file comparisons retain their documented limitations. |
| L11 | Fixed | Read failures, oversize files and non-regular-file mismatches discard an observation hint without blocking other observations. Manifest/SQLite corruption and manifest-write failures remain errors. Failed commands can roll back queue deletion; replay is idempotent and a later successful command drains it. The regression checks oversized-file preservation, valid observations, queue drainage and subsequent exports. |
| I23 | Confirmed and fixed | Check cancellation around post-commit refresh and propagate a saved-import cancellation message. Batch execution stops by its usual error policy; committed source revisions and successful audit records remain saved. Pending observations replay later. A deterministic signal-injection test checks this boundary. |
| F9 | Fixed and measured by decode counts | Import reporting reads the selected revision's indexed deck version; deletion reporting also avoids extracting source. `ReadDeckMetadata` supplies filenames without zstd decompression for untracked verification. Metadata errors are caught per row. Instrumented tests require one decode per unchanged imported deck and one per tracked verification render, with no extra metadata pass. |
| X19 | Fixed | Stages carry a held `.owner` advisory lock, and cleanup tries that lock rather than consulting local PIDs. Atomic-write temporaries stay locked through rename/sync too. Tests cover a locked stage with a nonexistent local PID and an unlocked stage with a live unrelated PID. Shared filesystems must provide working advisory locks, as required by SCU's existing library/output locking. Legacy unmarked stages are retained for manual cleanup. |
| M27 | Fixed or deliberately retained recovery data | Remove dead filename fallbacks and check deck existence/deletion before constructing its working path. Recovery-write failures preserve the original validation diagnostic and remove empty failed-recovery directories. A recovery file and its containing directory are intentionally retained until the user rescues the edit; automatic removal would discard it. Failure injection and existing retained-edit regressions cover both outcomes. |
| C3 | Revalidated | The group-preservation test already passes `replace=yes`; hosts without a second writable group still skip it. This review did not exercise it. |
| P17, P19 | Revalidated | Existing batch/editor-interrupt, failed-build history and wrapped-word regressions remain in the full suite. These were already fixed; the review did not read/run their tests. |

Additional notes: schema-7's one-way upgrade and creation of the working manifest
on first import are now explicit in the README. `output_file=scu$last_modified_deck`
now uses that deck's recorded source filename, consistently with the default.
Long hashed IDs intentionally provide collision-resistant identity while retaining
exact filenames; shorter interactive filename selectors would be a separate UX
feature. The prior commit is left intact; no history rewriting is proposed to
split an already reviewed commit. Future commits can separate independent
behavior and refactoring changes.

Validation of the b2688d9 fixes at 5d70945: `make test` passed: 271 tests run, 270
passed and one skipped because this host has no second writable group. The ten
new regression tests cover the findings above, and the executor probe and catalog
checks passed. `git diff --check` passed.

---

# Disposition of Claude's review of 6afc937

This records the disposition of every issue listed as open in
`claude/review-6afc937.md`. The original review is unchanged. “Design decision”
means an explicit retained contract, not a deferred bug fix. No item below is
left “partly fixed” without a decision.

## High and medium findings

| ID | Disposition | Change or reason |
| --- | --- | --- |
| X13 | Fixed | Cleanup defaults to deleting only records owned by this library. Untracked/foreign matching files are kept and named; `replace=yes` authorizes their removal. Removed files are named too. This tightens the earlier, deliberately broad cleanup specification to match overwrite protection. |
| X14 | Fixed | Rendering returns the selected revision's recorded source filename. Single/bulk extraction, release cleanup and untracked-file verification use it. Duplicate destinations are rejected before publication. Original filename bytes are retained in new revisions; the archive importer now stages actual root filenames rather than numeric temporary names. |
| L8 | Fixed | Scanned filenames that do not fit the deck-ID grammar receive a stable `file-<SHA-256>` ID. Their real filenames are stored separately, so spaces, Unicode and long filenames remain usable without skipping files or silently taking incomplete snapshots. Ambiguous canonical deck bindings still fail atomically. |
| L9 | Fixed | Import queues working-file observations in SQLite with the revisions and audit outcome, then updates the working manifest after commit. Extraction/verification retry outstanding observations. Audit failure rolls the queue back; a kill after database commit can replay it. Replay never writes source files and only acknowledges bytes that still match. Missing imported sources remove their raw-file record after deletion commits. |
| M1 | Fixed | One typed registration table specifies the handler, command mode, output-lock policy and report hook. Dispatch is a lookup, and catalog validation still rejects unsupported handlers before I/O. Dead checkpoint preparation plumbing is removed. |
| M22 | Fixed at responsibility boundaries | Read-only queries and snapshot selectors moved out of the library facade. Header, revision and filename rules have their own units. The existing facade aliases preserve callers and ownership. Catalog parsing/validation remains together because loading a valid typed catalog is one cohesive operation; a universal unit-line limit is not adopted. |
| D1 | Design decision: bounded search | The 3,072-edit and 256 MiB search-work limits prevent pathological diff resource use. Exceeding a limit emits a complete replacement, not missing or incorrect source. Minimal hunks are not guaranteed. Existing boundary/full-patch regressions are retained, and multi-file application is tested. Removing the bound would trade predictable resource use for presentation quality. |
| M5 | Design decision: canonical serialization plus typed caches | Domain access uses typed definitions/records. The header/revision owners also retain their canonical JSON representation to preserve audited field order and unknown extensions. Typed caches are private, initialized by validation and changed only through owner mutators. Rebuilding JSON from properties would weaken audit compatibility; retaining this serialization boundary is intentional. |

## Remaining low findings

| ID | Disposition | Change or reason |
| --- | --- | --- |
| C3 | Fixed | The group-preservation test passes `replace=yes`. It still legitimately skips when there is no second writable group on the test host. |
| X15 | Fixed | Private staging directories live under the output directory, include the owning PID, and are cleaned after normal completion. One-shot commands now install the same termination handlers as sessions. Recovery removes unlocked stages without following links or recursively deleting unknown contents; stages with held ownership locks are retained (X19). The PID in the name is diagnostic only. A forced kill necessarily defers cleanup until the next operation. |
| X17 | Fixed | Release and verification each warn once when a selected deck contains a former COPY directive. Source remains literal. The removal is explicitly documented as breaking. |
| X16 | Fixed | In-memory manifest identities use fixed-length SHA-256 keys. Full path bytes remain separately encoded in JSON; long common filename prefixes cannot truncate map keys. |
| F8 | Fixed | Publication rechecks the destination checksum, skips replacement/fsync for identical bytes, and still updates the manifest. Inode/mtime preservation is tested. |
| D3 | Fixed for textual unified version diffs | Headers use `a/<recorded filename>` and `b/<recorded filename>` in both modes, with deck versions after a tab. Exact patch applicability requires `ignore_space_changes=no`. An application test covers multiple changed, added and removed files with `patch -p1`. Normal comparison output and single-deck descriptive labels are retained. Binary differences and empty-deck notices are comparisons, not executable patch instructions. |
| I10 | Fixed pager resizing; deliberate key timing | SIGWINCH restarts the completion page using current dimensions and retains the command draft/cursor. The editor intentionally uses one horizontally scrolling row. The 500 ms lone-Escape and 1 s sequence timeouts are retained to distinguish Escape from delayed terminal/SSH key sequences. |
| M11 | Scoped fix; remaining naming is style | New domain/query implementations use `strict private`; library storage/extraction use named option sets and output locks use an enum policy. Methods taking selection/query parameters remain methods. Converting every accessor or unit-private loader helper to a property is not a correctness requirement. |
| M12 | Closed: ownership is explicit | Store-owned lazy entries are documented as borrowed; returned value records/arrays are managed values; configuration copies are caller-owned; `var` JSON handoffs clear the original owner. Executor cleanup remains centralized in `finally`. No outstanding lifetime defect was identified; constructor/factory names need not all encode Pascal's conventional ownership rules. |
| M14 | Context improved at owner boundaries | Header validation adds library/recovery context; recovery construction names the input recovery file. Revision/source validation identifies its deck/payload, and JSON/filesystem parsers already name their inputs. Missing an optional `Field` source argument is not itself a defect when the enclosing owner supplies context. Cancellation remains a separate exception and is not wrapped. |
| M16 | Guarded compatibility hook; deliberate serialization state | Unloaded payload access still raises; assigning a modern/already assigned revision number now raises. The remaining legacy-number hook initializes old numberless payloads without rewriting audited bytes. Header caches follow the M5 serialization decision. |
| M17 | Closed: responsibility, not line count | Registry dispatch, library queries and model responsibilities have been separated. Remaining long routines implement bounded diff search, child-process supervision or event loops with shared local invariants and cancellation tests. Their length alone is not a defect; further extraction requires a concrete independent responsibility rather than an arbitrary line limit. |
| M18 | Fixed applicable layering | Snapshot result data moved below audit/executor into its own unit. Output lock selection is a named enum. Ordinary SCU-error catches cannot swallow cancellation because it has a separate exception root. |
| M24 | Shared useful abstractions; retain explicit SQL ownership | Export mode is typed end-to-end, filename encoding/pattern matching are shared, and output handlers use the sink's column width. Owned SQLite statements deliberately keep prepare/bind/step/free visible and typed; a generic variant-valued SQL wrapper would not improve the ownership contract. Terminal dimension reads remain at actual terminal UI boundaries. |
| M25 | Fixed applicable flags/ownership; reader state is deliberate | Store/extract options and lock policies are named types. Importing has a correctly named owner; manifest recovery is explicit; dead save/checkpoint state is gone. Command-file frames are already records, not parallel lists. The terminal/pipe/file reader's local flags represent real input states; adding a second source-object hierarchy solely to move those flags is not adopted. |
| M26 | Fixed active leftovers | Remove unused checkpoint store/table, bulk COPY/cache APIs, dead macro branches and render timestamp state. Keep only compatibility validation for COPY metadata already covered by historical audit digests; new revisions never scan/cache COPY (this was already true in 6afc937; that part of the review was inaccurate). Export/render unit names now reflect their jobs. Mode conversions and the redundant file check are removed; redundant ordinary-error cancellation re-raises are removed while generic-exception protection remains. |
| P17 | Revalidated | Regression coverage confirms command-file comments and editor-handled Ctrl+C stopping a batch after preserving saved edits; `continue_on_error=yes` continues explicitly. |
| P19 | Revalidated | A regression reconstructs a wrapped history command across rows and checks word boundaries; existing failed-build history tests remain. |
| P20 | Fixed invalid-edit loss; intentional kill recovery | Invalid pattern edits are preserved in a private recovery file and the error gives its path. A SIGKILL cannot execute cleanup. Private editor working files left by a forced kill are deliberately retained because they can contain the only copy of an edit; automatic deletion would lose recoverable user work. Recovery instructions are documented. |
| P21 | Clarified and reported | Deletion names a kept working file and explains that import will recreate it. Bare edit/extract reports a deleted last-modified deck and requires an explicit choice. The attribute still means the literally last modified deck (including a tombstone), so default history remains useful; SCU does not silently substitute another deck. |

## Review notes without issue IDs

- **Manifest permissions:** 0600 is intentional for local tracking state containing
  absolute paths. Source output permissions remain governed by umask or existing
  file permissions. The manifest is not a required public release artifact.
- **Binary macro occurrences:** release has an explicit byte-token substitution
  contract, including binary bytes. Extraction is the byte-exact operation.
  Per-file macro policy would be a new feature, not a defect in this contract.
- **Restoring old versions:** extraction changes working files, not the current
  library version. A subsequent explicit import records their contents as new
  revisions. This is documented; no hidden import/version change is added.
- **Locking with unimported edits:** locking freezes the stored snapshot.
  Automatically importing or scanning external edits would change the meaning of
  that command. The help/workflow now reminds users to import first.

## Historical validation of the 6afc937 fixes

Regression tests cover the four data/workflow fixes, observation replay and audit
rollback, long filename identities, actual filename preservation, stale stages,
termination, COPY warnings, unchanged-file writes, patch application, interrupted
batch editing, history wrapping, pager resizing and retained invalid edits. The
full integration suite and canonical catalog checks passed: 261 tests run, 260
passed and one skipped because this host has no second writable group. The
executor probe also passed, including legacy revision initialization guards.
`git diff --check` passed.
