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
| X15 | Fixed | Private staging directories live under the output directory, include the owning PID, and are cleaned after normal completion. One-shot commands now install the same termination handlers as sessions. Recovery removes dead-PID stages without following links or recursively deleting unknown contents; live-PID stages are retained. A forced kill necessarily defers cleanup until the next operation. |
| X17 | Fixed | Release and verification each warn once when a selected deck contains a former COPY directive. Source remains literal. The removal is explicitly documented as breaking. |
| X16 | Fixed | In-memory manifest identities use fixed-length SHA-256 keys. Full path bytes remain separately encoded in JSON; long common filename prefixes cannot truncate map keys. |
| F8 | Fixed | Publication rechecks the destination checksum, skips replacement/fsync for identical bytes, and still updates the manifest. Inode/mtime preservation is tested. |
| D3 | Fixed for textual unified version diffs | Headers use `a/<recorded filename>` and `b/<recorded filename>`, with deck versions after a tab. An application test covers multiple changed, added and removed files with `patch -p1`. Normal comparison output and single-deck descriptive labels are retained. Binary differences and empty-deck notices are comparisons, not executable patch instructions. |
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

## Validation

Regression tests cover the four data/workflow fixes, observation replay and audit
rollback, long filename identities, actual filename preservation, stale stages,
termination, COPY warnings, unchanged-file writes, patch application, interrupted
batch editing, history wrapping, pager resizing and retained invalid edits. The
full integration suite and canonical catalog checks passed: 261 tests run, 260
passed and one skipped because this host has no second writable group. The
executor probe also passed, including legacy revision initialization guards.
`git diff --check` passed.
