# REBASE — RemoteControlService

This document explains how to bring the nine patches in `patches/`
up to date when a new AOSP release shifts the file layout, and how
to update the SELinux policy overlay in
`device/qalos/qalos_emulator/sepolicy/`.

> **v0 history note.** The original v0 had four patches
> (0001-Android.bp srcs, 0002-permission, 0003-strings,
> 0004-SystemServer). Patch 0001 was deleted in the `fix-ups-2`
> commit because AOSP 15's `services.core-sources` filegroup
> already globs `srcs: ["java/**/*.java"]`, which picks up our
> copied `com/qalos/remotectl/*.java` without an explicit srcs
> entry. The dry-run procedure in
> [`website/docs/qa-lab-os/lessons-learned.md`](../../../website/docs/qa-lab-os/lessons-learned.md)
> caught this.
>
> **v0 fix-ups-3 note.** The AIDL was replaced with a plain
> Java interface (`com.qalos.remotectl.IRemoteControl`) so the
> service no longer depends on AIDL compilation wiring that
> changed between AOSP releases. The SELinux policy overlay
> is in the qalos device tree and ships with the overlay, so it
> does not need to be re-applied on AOSP rebases.

## When to rebase

Run `check-patches.py` after every `repo sync` that pulls a new
AOSP revision. If any patch reports `FAIL`, the rebase is
required.

## How to rebase

For each failing patch:

1. **Open the upstream AOSP file** that the patch targets. The
   patch's source code comment tells you which one.

2. **Compare** the patch's anchor (the string the regex matches)
   against the current file content. The mismatch is usually:
   - The anchor class or method renamed (e.g.
     `traceBeginAndSlog` → `t.traceBegin` in AOSP 15).
   - Whitespace differences (tabs vs spaces, indent depth).
   - A few lines added or removed around the anchor.

3. **Apply the change manually** by editing the patch script
   in `patches/`. Update both the regex pattern and the
   `NEW_BLOCK` constant. The script is the source of truth;
   the diff between the script and the upstream file is the
   change being applied.

4. **Verify** with the dry-run recipe in
   [`lessons-learned.md`](../../../website/docs/qa-lab-os/lessons-learned.md).
   Download the real upstream file, run `check-patches.py`
   against the fake working tree, and confirm all nine
   patches report `OK`.

5. **Commit** the change as a follow-up commit titled
   `qalos: rebase <patch-name> onto <new-AOSP-tag>`. Reference
   the original patch name and the new AOSP tag in the commit
   body.

## Common rebase hazards

- **SystemServer.java** is refactored often. The InputManager
  start block uses a local `Trace t` instance in AOSP 15
  (`t.traceBegin("StartInputManagerService"); ... t.traceEnd();`).
  The exact `t.` prefix and method name may change. Always
  verify the actual AOSP file before re-writing the patch.

- **AndroidManifest.xml** is huge; the closing `</manifest>` is
  the only safe anchor for the permission insertion.

- **strings.xml** is split across many resource directories
  (values/, values-en-rGB/, etc.). The patch only targets
  `values/strings.xml`; translations are not required for the
  build to succeed.

- **An idempotency check that spans the file will lie to you.** Patch
  0005's guard was
  `re.search(r"<!-- @SystemApi @hide[\s\S]*?REMOTE_CONTROL[\s\S]*?/>", text)`.
  `[\s\S]*?` is unbounded, so it scans the whole 9,000-line
  `AndroidManifest.xml`; an unrelated `@hide` comment hundreds of lines
  earlier satisfies it and the patch reports `already applied` against a
  tree it never edited. It printed that line on **every** run for months
  and the build still failed on the gate the patch exists to satisfy.
  Fixed 2026-09-28 to use an exact `NEW_BLOCK in text` test. **Rule: a
  patch's "already applied" is a claim, not a fact — when a build fails
  on something a patch claims to handle, grep the tree for the actual
  marker before believing the patch ran.** See
  [`tools/gcp/LESSONS.md`](../../../tools/gcp/LESSONS.md) §3.

## The permission gate: 0002 / 0005 / 0007 / 0008 / 0010

Five patches cooperate here, and they are easy to misread as
independent. The chain:

| Patch | File | Job |
|---|---|---|
| 0002 | `core/res/AndroidManifest.xml` | declare the `REMOTE_CONTROL` signature permission |
| 0005 | `core/res/AndroidManifest.xml` | annotate it `@SystemApi @hide` |
| 0007 | `core/api/current.txt` | **remove** any `REMOTE_CONTROL` line — a `@hide` permission is not public API |
| 0008 | `core/api/system-lint-baseline.txt` | add an `UnflaggedApi` baseline entry |
| 0010 | `core/api/system-current.txt` | add the permission to the **system** API list |

**Do not "fix" a build failure here by editing `current.txt`.** A
`<permission>` added to the platform manifest is new public API surface;
metalava rejects it in `api-stubs-docs-non-updatable` with:

```
error: New API must be flagged with @FlaggedApi:
  field android.Manifest.permission.REMOTE_CONTROL [UnflaggedApi]
```

The correct fix is the `@hide` comment marker that AOSP itself uses —
243 permissions in that same manifest do it. Evidence that the convention
works: `TV_VIRTUAL_REMOTE_CONTROLLER` and
`CHANGE_HDMI_CEC_ACTIVE_SOURCE` both carry `@hide` and both score **0**
in `core/api/current.txt`, while `ACCESS_NETWORK_STATE` (no marker)
scores 4 and `DUMP` scores 1.

**`@FlaggedApi` is a dead end on this product.** It is accepted by
metalava, but aapt2 then fails with
`attribute 'android:featureFlag' has flag ... not found in flags from
--feature_flags parameter`, because aapt2's flag list comes from the
`aconfig_declarations` that are transitive deps of `framework-res` and
`qalos.aconfig` lives in `services.core`, which is not in that graph.
Making the flag work would mean moving the aconfig into a library listed
in `frameworks/base/core/res/Android.bp`'s `flags_packages`.

**Verification after touching any of these five patches:**

```bash
# the marker must be on the permission, not just somewhere in the file
grep -n -B1 'REMOTE_CONTROL' frameworks/base/core/res/AndroidManifest.xml
# expect:  <!-- @SystemApi @hide   (immediately above the <permission>)

# and the build must be clean on the two gates that matter
grep -c 'error:'        build.log   # 0
grep -c 'UnflaggedApi]' build.log   # 0   <- the bracket matters, see below
```

> `grep -c 'UnflaggedApi'` (no bracket) returns **1 on a clean build**,
> because it matches patch 0008's filename in the line
> `[apply-qalos] status=ok patch=0008-system-lint-baseline-UnflaggedApi-REMOTE_CONTROL.py`.
> Only `UnflaggedApi]` is a real error. This cost a false alarm on
> 2026-09-28.

**Do not trust a self-heal that regenerates the API baseline.** The
retry in the build script ran
`m api-stubs-docs-non-updatable-update-current-api`, which is not a real
target; it failed `exit status 255` and attempt 2 failed identically.
Suppressing the lint is also the wrong lever — `@hide` fixes the API
*surface*, which is what both `UnflaggedApi` and `check_current_api`
were objecting to.

## When the rebase cost exceeds the value

If a rebase takes more than 1 working day, or if two AOSP
releases in a row have made the patches un-mergeable, fork
`frameworks/base` in `default.xml` and maintain our own copy.
Document the fork in `website/docs/qa-lab-os/decisions.md` as
a new D-XXX entry.

## Real-AOSP dry-run is the test of record

**Do not declare a patch "ready" without a successful dry-run
against the actual upstream file.** Two 4-pass AI reviews
missed three real bugs in v0 (deleted patch 0001, wrong
SystemServer anchor, `len(sys.argv > 1)` crash). The 5-minute
download-and-dry-run procedure caught all three. The recipe
is in [`lessons-learned.md`](../../../website/docs/qa-lab-os/lessons-learned.md).
