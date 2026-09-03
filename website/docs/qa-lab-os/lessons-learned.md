---
id: lessons-learned
title: Lessons learned (v0)
sidebar_label: Lessons learned
sidebar_position: 10
description: What we got wrong, what we got right, and what to do differently next time.
---

# Lessons learned — QA Lab OS v0

This page captures the things the agent got wrong, the things it
got right, and the rules we want the next contributor to follow.
It is the human-facing mirror of the agent-memory entries; both
should stay in sync.

## What we got wrong

### 1. Patches 0001 and 0004 were written from memory, not against the upstream tree

The agent drafted the four patches by reasoning about what
`frameworks/base/services/core/Android.bp` and
`frameworks/base/services/java/com/android/server/SystemServer.java`
*probably* looked like in AOSP 15. It was wrong on both:

- **Patch 0001** added `"java/com/qalos/remotectl/*.java"` to the
  `services.core` `java_library` `srcs:`. The actual AOSP 15 file
  has no `srcs:` on `services.core` at all — the sources are in
  the `services.core-sources` filegroup, which has the glob
  `srcs: ["java/**/*.java"]` and therefore already picks up our
  copied `com/qalos/remotectl/`. The patch was unnecessary; deleting
  it does not change the build.

- **Patch 0004** targeted the static `traceBeginAndSlog` method
  and a bare `traceEnd();` line in SystemServer. AOSP 15 replaced
  the static method with a local `Trace t` instance. The actual
  lines are `t.traceBegin("StartInputManagerService");` /
  `t.traceEnd();` — note the `t.` prefix on both. The patch's
  regex and the inserted block both need to use the `t.` prefix
  to match.

A subsequent pass (the user explicitly asked for more research)
combined the download-and-dry-run with a web-research step and
caught two more design gaps that the dry-run alone could not find
(because the dry-run is text-based and these were missing-pieces
gaps, not text-mismatch gaps):

- **AIDL wiring.** The AIDL file was at
  `services/core/java/com/qalos/remotectl/IRemoteControl.aidl`
  but the `services.core-sources` filegroup globs `*.java` only;
  the AIDL was never compiled, and the build would have failed
  with `cannot find symbol: class IRemoteControl`. Fix: replaced
  the AIDL with a plain Java interface, removed
  `publishBinderService`, removed `enforceCallingPermission`. A
  v1+ that wants Binder can re-introduce the AIDL by moving it
  to `core/java/android/os/` and patching
  `frameworks/base/Android.bp`.

- **SELinux policy.** AOSP requires `service_contexts`,
  `service.te`, and `system_server.te` entries for any new system
  service that binds a TCP socket; the v0 had none. Fix: added a
  sepolicy overlay in `device/qalos/qalos_emulator/sepolicy/`
  and wired it via `BOARD_SEPOLICY_DIRS` in `device.mk`.

The lesson: the dry-run catches text-level mismatches. The
web-research step catches architectural-level gaps ("you're not
editing file X at all"). Both are needed.

The fix: download the four target files from
`https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/<path>?format=TEXT`,
decode the base64, drop them into a fake AOSP working tree at
the right relative paths, and run the patch scripts against the
tree. **5 minutes of setup catches bugs that two review passes
missed.**

### 2. `len(sys.argv > 1)` is a `TypeError`, not a comparison

The patch 0004 script had:
```python
work_tree = Path(sys.argv[1]) if len(sys.argv > 1) else Path.cwd()
```

The expression `sys.argv > 1` is evaluated eagerly; comparing a
`list` to an `int` raises `TypeError` before the `if` is even
checked. The intended form is `len(sys.argv) > 1`. The crash was
masked because `check-patches.py` and `apply-qalos.sh` both
always pass the work tree as `$1`, so the bad expression never
actually ran in normal use — but a direct invocation crashes
immediately.

### 3. The self-review had two blind spots

The agent performed two 4-pass reviews (one before the v0 commit,
one after) and **missed** the two real bugs above. The reviews
caught AOSP-deprecated APIs, missing permissions, missing
documentation, and a few style issues. They did not catch:

- Patch anchors that don't match the real upstream file.
- API references that the upstream has removed.
- Compile errors in scripts (because the scripts run in
  Python, not in `m`).

The download-and-dry-run is a third review pass that does not
share the blind spot. Add it to the standard cycle.

## What we got right

### 1. Python-based patches instead of `git apply` unified diffs

The original PRD sketched `git format-patch` style diffs. The
agent rejected that in favour of Python scripts that use
`str.replace` / `re.subn` on a known anchor. The reasoning: AOSP
releases shift line numbers; a script keyed on a stable anchor
survives rebase without manual intervention.

**Verdict:** correct call. Patch 0004 still needs a rebase (its
anchor is wrong), but patches 0002 and 0003 apply cleanly with no
line-number maintenance. Patches written as unified diffs would
have needed a rebase on every AOSP release.

### 2. The privileged system app fallback

The PRD documented the "true native" framework service path AND
the "middle ground" privileged system app path. The user picked
the framework service path knowing the maintenance cost. The
agent also documented the escape hatch in `decisions.md` and
`REBASE.md`: if two AOSP releases in a row make the patches
un-mergeable, fork `frameworks/base` in `default.xml`. The
documentation makes the trade-off explicit at the point of
decision, not after the fact.

### 3. The 4-pass review at all

The 4-pass model caught 52 findings across four lenses, 12 of
which were must-fix. Even with the blind spots above, the
process produced a measurably better PR than a single holistic
review would have. The reports are the audit trail.

### 4. Pre-flight patch checking

`check-patches.py` runs every patch in dry-run mode before any
are applied. Without it, a broken patch would be silently
applied and the failure would surface at `m` time, hours later.
With it, the failure surfaces in 1 second at apply time. (The
check still needs the download-and-dry-run to be effective — see
above.)

## What to do differently next time

| # | Rule | Source |
| --- | --- | --- |
| 1 | **For any framework patch, download the actual upstream file and dry-run the patch against it in a sandbox** before declaring it ready. 5 minutes, catches real bugs. | This page + agent memory. |
| 2 | **Never write a patch from memory of the upstream file.** Read the file, paste the anchor from the file, and verify the anchor after writing. | This page. |
| 3 | **Treat `traceBeginAndSlog` (and any other "static helper" pattern) as AOSP-internal and possibly removed in the next release.** Use the local-Trace-instance pattern instead. | AOSP 15. |
| 4 | **Use `t.traceBegin` / `t.traceEnd`, not bare `traceBegin` / `traceEnd`, in SystemServer patches.** The `t.` prefix is mandatory in AOSP 15. | AOSP 15 SystemServer.java. |
| 5 | **Before adding a new file to the overlay, grep the upstream build files for matching globs.** AOSP 15's `services.core-sources` filegroup already globs `java/**/*.java`; your new `package/app/Foo.java` is already in the build. Don't add a patch that adds a line that is already covered by a glob. | AOSP 15 services/core/Android.bp. |
| 6 | **When you write `len(x > 1)` you almost certainly meant `len(x) > 1`.** The first is a TypeError. | Python operator precedence, common typo. |

## The 5-min download-and-dry-run recipe

```powershell
$ErrorActionPreference = 'Stop'
$base = "https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1"
$out  = ".tmp/aosp-15"
New-Item -ItemType Directory -Force -Path $out | Out-Null

# 1. Fetch each target file
$files = @(
  "services/core/Android.bp",
  "core/res/AndroidManifest.xml",
  "core/res/res/values/strings.xml",
  "services/java/com/android/server/SystemServer.java"
)
foreach ($f in $files) {
  $url = "$base/$($f)?format=TEXT"
  $dst = Join-Path $out $f
  New-Item -ItemType Directory -Force -Path (Split-Path $dst) | Out-Null
  $resp = Invoke-WebRequest -Uri $url -UseBasicParsing
  $bytes = [System.Convert]::FromBase64String($resp.Content)
  Set-Content -Path $dst -Value ([System.Text.Encoding]::UTF8.GetString($bytes)) -Encoding utf8
}

# 2. Mirror into a fake AOSP working tree
$wt = ".tmp/aosp-15-frameworks"
New-Item -ItemType Directory -Force -Path "$wt/frameworks/base" | Out-Null
Copy-Item -Recurse "$out/services" "$wt/frameworks/base/services"
Copy-Item -Recurse "$out/core"     "$wt/frameworks/base/core"

# 3. Run the pre-flight
python3 packages/apps/RemoteControlService/patches/check-patches.py $wt

# 4. Run each patch individually
foreach ($p in Get-ChildItem packages/apps/RemoteControlService/patches/000*.py) {
  python3 $p.FullName $wt
}
```

If `check-patches.py` exits non-zero, the patch has a bug. The
output tells you which anchor didn't match.

## What the next agent should add

These are the deferred/wontfix items from the v0 review. Track
them so the v1 branch picks them up:

- F-1.16 — `display_size` cache invalidation on rotation
- F-2.3 — per-client rate limit on `/screenshot`
- F-2.4 — structured error codes (replace leaking `e.getMessage()`)
- F-3.3 — `HttpApiServer` dispatch table (replaces switch + if-ladder)
- F-3.6 — `QaLabError.code` and `QaLabError.http_status` fields

## See also

- [`v0 plan`](./plan) — what was in scope and out of scope
- [`decisions log`](./decisions) — opinionated choices, with rationale
- [`static check workflow`](./static-checks) — the 4-pass model
- [`review log`](./review-log) — the per-pass reports
- [`REBASE.md`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/packages/apps/RemoteControlService/REBASE.md) — rebase runbook for the framework patches
