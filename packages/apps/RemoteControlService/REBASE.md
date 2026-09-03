# REBASE — RemoteControlService

This document explains how to bring the three patches in `patches/`
up to date when a new AOSP release shifts the file layout.

> **v0 history note.** The original v0 had four patches
> (0001-Android.bp srcs, 0002-permission, 0003-strings,
> 0004-SystemServer). Patch 0001 was deleted in the `fix-ups-2`
> commit because AOSP 15's `services.core-sources` filegroup
> already globs `srcs: ["java/**/*.java"]`, which picks up our
> copied `com/qalos/remotectl/*.java` without an explicit srcs
> entry. The dry-run procedure in
> [`website/docs/qa-lab-os/lessons-learned.md`](../../../website/docs/qa-lab-os/lessons-learned.md)
> caught this.

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
   against the fake working tree, and confirm all three
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
