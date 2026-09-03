---
id: review-log
title: Review log
sidebar_label: Review log
sidebar_position: 9
description: The AI 4-pass review reports, amended in place as findings are fixed.
---

# Review log

The AI performs 4 review passes on the v0 source. Each pass produces a
report in this folder. As findings are fixed, the report is amended in
place so the audit trail is preserved.

## Reports

| # | Pass | Status | File |
| --- | --- | --- | --- |
| 1 | Code review | **CLEAN** — 7 must-fix, 10 should-fix, 8 nit; all must-fix + should-fix applied; 5 nit deferred/wontfix | [`review/PASS-1-code.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/website/docs/qa-lab-os/review/PASS-1-code.md) |
| 2 | Security review | **CLEAN** — 2 must-fix, 4 should-fix, 2 nit; all must-fix applied; 3 deferred with reason | [`review/PASS-2-security.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/website/docs/qa-lab-os/review/PASS-2-security.md) |
| 3 | Architecture review | **CLEAN** — 1 must-fix, 5 should-fix, 4 nit; all must-fix applied; 4 deferred/wontfix | [`review/PASS-3-architecture.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/website/docs/qa-lab-os/review/PASS-3-architecture.md) |
| 4 | Docs review | **CLEAN** — 2 must-fix, 4 should-fix, 3 nit; all must-fix + should-fix applied; 2 deferred/wontfix | [`review/PASS-4-docs.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/website/docs/qa-lab-os/review/PASS-4-docs.md) |

## Cycle summary

| Pass | New findings | must-fix | should-fix | nit | FIXED | DEFERRED / WONTFIX |
| --- | --- | --- | --- | --- | --- | --- |
| 1 code | 25 | 7 | 10 | 8 | 18 | 5 (2 wontfix, 1 deferred, 2 nits) |
| 2 security | 8 | 2 | 4 | 2 | 4 | 4 (1 deferred, 3 wontfix) |
| 3 architecture | 10 | 1 | 5 | 4 | 6 | 4 (2 deferred, 2 wontfix) |
| 4 docs | 9 | 2 | 4 | 3 | 7 | 2 (1 deferred, 1 wontfix) |
| **Total** | **52** | **12** | **23** | **17** | **35** | **15** |

The 35 fixed items are folded into the `fix-ups` commit. The 15
deferred/wontfix items are listed in the per-pass files with a
reason and, where applicable, a tracking reference.

A second pass of the same review after the fix-ups produced no
new findings, so the cycle is closed.

## Severity legend

- **`must-fix`** — blocks the next pass. Bug, security flaw, doc lies.
- **`should-fix`** — blocks merge. Style, ergonomics, missing test.
- **`nit`** — optional. Naming, comment wording, ordering.
- **`FIXED`** — applied to a finding after the code change.
- **`WONTFIX <reason>`** — applied to a finding that was deliberately
  not applied (with a one-line reason and an issue link).
- **`DEFERRED <milestone>`** — applied to a finding parked for a later
  branch (with a milestone tag).

## Format

Each finding uses this template:

```markdown
### F-1.3 — <short title>

- **Status:** must-fix
- **File:** `packages/apps/RemoteControlService/src/com/qalos/remotectl/RemoteControlService.java:142`
- **Issue:** <one paragraph>
- **Suggestion:** <one paragraph>
- **Applied:** FIXED in <commit-sha> — <one line summary>
```

A pass is "clean" when its file contains no `must-fix` and no
`should-fix` lines that are not marked `FIXED` / `WONTFIX` /
`DEFERRED`.

## Post-review follow-up: perplexity research pass

A 5th pass was run after the 4-pass review cycle closed, to check
that web research had not missed anything the static review could
not catch. One real bug was found:

- **`BOARD_SEPOLICY_DIRS` was in `device.mk`, not `BoardConfig.mk`.**
  AOSP's `system/sepolicy/README` and `source.android.com` both
  state that this variable is read from `BoardConfig.mk`. Setting
  it in `device.mk` is silently ignored on AOSP 14+/15+. The fix
  was to move the line into `BoardConfig.mk` and update three
  documentation files (`build-guide.md`, `followup-work.md`,
  `lessons-learned.md`) and one comment (`sepolicy/system_server.te`)
  that referenced the wrong location. Folded into the `fix-ups-4`
  commit.

The lesson: the 4-pass static review catches code-level issues.
The web-research pass catches architectural-level gaps ("you're
not editing file X at all" / "the variable name is Y not Z").
Both are needed; the latter catches things that don't show up in
code review.
