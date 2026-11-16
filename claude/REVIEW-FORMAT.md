# SCU review format

This file describes the format of the code reviews in this directory. Each review
covers the commits since the previous review and is saved as
`claude/review-<commit>.md`, where `<commit>` is the short hash of the last commit
reviewed.

## Sections

A review has these sections, in this order.

### 1. Header

- **Title:** `# SCU code review — commit <hash>`.
- **Reviewer**, **Date**, **Previous review** (path of the previous review file).
- **Scope:** the commits covered with their rough size, the main changes, any extra
  request (for example a performance profile or a best-practice audit), and
  anything that was not checked.

### 2. Issue labels

The area letters and the severity and priority definitions, repeated in every
review so that it can be read on its own. See "Issue IDs", "Severity" and
"Priority" below.

### 3. How this was checked

Build and test result, what was read, which scenarios were run (workflow, crash
safety, speed, compatibility), and what was not re-tested.

### 4. Summary

A numbered list: what works, the High issues, the Medium issues, the Low issues in
one line, and the open count compared with the previous review.

### 5. Status of the issues open at the previous review

A table with one row for each issue that was open at the previous review:

| ID | Status | Evidence | Coder comments |
|---|---|---|---|

- **Evidence** says how the status was established: a file and line, a command
  and its output, or a measurement.
- Issues with the same status and nothing to add may share a row.

### 6. Review of the changes

- **What's good:** design decisions and fixes worth keeping.
- **Findings**, grouped High, Medium, Low. Each finding starts with
  `ID · Severity · Priority — title`, followed by the cause with file and line,
  a reproduction, the effect, and a suggested fix.
- **Best-practice audit** (only when requested): findings under area M, with a
  suggested refactoring order and the units to leave alone.
- **Notes (no issue IDs):** observations that need no action or are design
  questions.

### 7. Recommended order

A numbered order in which to fix the open issues.

### 8. Issue status at `<commit>`

One table with every ID ever raised:

| ID | Issue | Severity | Priority | Status | Coder comments |
|---|---|---|---|---|---|

Sorted with open issues first, then closed ones; within each group by severity
(High → Low), then priority (P1 → P3), then ID.

## Issue IDs

Every finding has a stable ID: an area letter plus a number. IDs are shared across
all reviews. An issue keeps its ID until it is closed, and a number is never
reused.

| Letter | Area |
|---|---|
| L | Library storage, versions and revisions |
| A | Audit log |
| X | Expansion and build command |
| D | Diff |
| P | Command line: parsing, commands, editor |
| I | Interactive terminal: line editor, completion, history, signals |
| F | Speed (performance) |
| C | Configuration, build, tests, tooling, repository |
| M | Code structure and maintainability |

## Severity

Severity is the impact of the issue.

| Severity | Meaning |
|---|---|
| High | Lost or overwritten data, wrong output, code run that the user didn't ask for, or a hang or crash. |
| Medium | Edge-case errors, misleading behaviour, a sizeable slowdown, or (for M) structure that makes changes risky. |
| Low | Cosmetic, minor, or a future risk. |

## Priority

Priority is when to fix the issue.

| Priority | Meaning |
|---|---|
| P1 | Before the next feature. |
| P2 | Within the next few commits. |
| P3 | When convenient, or a design decision. |

## Status

The reviewer sets the Status column (see "Closing an issue"). "Fixed" always
means the reviewer verified the fix.

### Open statuses

| Status | Meaning |
|---|---|
| New | Raised in this review. |
| Open | Raised earlier and unchanged. |
| Partly fixed | Some of the issue is fixed; the status names what is left. |
| Mostly fixed | Only a small remainder is left; the status names it. |
| Regressed | Was fixed and is broken again. |

### Closed statuses

| Status | Meaning |
|---|---|
| Fixed | The code changed and the reviewer verified it. The status names the commit. |
| Documented | The behaviour stays; the README or help text now describes it. |
| Obsolete | The feature or code the issue was about has been removed. |
| Won't fix | A decision not to fix it, either permanently or for now (parked, for example because the work is out of proportion to the benefit). The reason goes in Coder comments. |
| Withdrawn | The reviewer was wrong or could not reproduce the issue. |
| Duplicate | Merged into another ID, which the status names. |

- A "Won't fix" issue is not repeated in the findings or the recommended order.
  The reviewer reopens it (status Open, same ID) if its area changes in a way
  that raises its severity, or if the coder asks.
- Reviews written before this file used "Closed" for what is now Documented,
  Obsolete or Withdrawn. Those rows are converted when the next review is
  written.

## Coder comments

The text in the Coder comments column is written by the coder, and only for open
issues.

- The coder adds comments to the open issues in the two tables of the latest
  review file: a proposed status ("fixed in abc1234"), a reason to park the
  issue, a disagreement with the finding, or a question.
- The coder does not change the Status column and does not comment on closed
  issues.
- The reviewer copies each comment unchanged into the next review and answers it
  in the Evidence column or in the finding.
- A comment on an open issue is kept until the coder changes or removes it. An
  empty cell means there is no comment.

## Closing an issue

Only the reviewer moves an issue to a closed status, where needed together with
the project owner.

- **Fixed, Documented, Obsolete, Duplicate:** the reviewer closes the issue after
  verifying it.
- **Withdrawn:** the reviewer closes the issue when the finding turns out to be
  wrong.
- **Won't fix:** the project owner decides, on the coder's comment and the
  reviewer's advice. Until then the issue stays open.
- When an issue is closed, its last coder comment stays in the table as the
  record of why.
