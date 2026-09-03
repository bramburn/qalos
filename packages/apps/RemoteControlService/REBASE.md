# REBASE — RemoteControlService

This document explains how to bring the four patches in `patches/`
up to date when a new AOSP release shifts the file layout.

## When to rebase

Run `verify-patches.sh` after every `repo sync` that pulls a new
AOSP revision. If any patch reports `FAIL`, the rebase is required.

## How to rebase

For each failing patch:

1. **Open the upstream AOSP file** that the patch targets. The patch
   subject line tells you which one (e.g. `[PATCH 2/4] framework
   manifest: add REMOTE_CONTROL permission` → `frameworks/base/core/res/AndroidManifest.xml`).

2. **Compare** the patch context (the lines starting with a space)
   against the current file content. The mismatch is usually:
   - A few lines added or removed around the patch anchor.
   - Whitespace differences (tabs vs spaces).
   - The anchor element renamed (e.g., `permission` -> `permission-group`).

3. **Apply the change manually** using `git apply -3` (3-way merge)
   or `git apply --reject` (apply what works, leave `.rej` files
   for the rest). For a 4-line patch this is usually faster than
   trying to regenerate the diff.

4. **Verify** with `git apply --check ../<patch>` from inside the
   file's directory. If the original `git apply` failed because the
   context shifted, the new `git apply --check` may pass after your
   manual edit (the patch will be considered "already applied" and
   `git apply` will report a no-op).

5. **Commit** the change as a follow-up commit titled `qalos: rebase
   <patch-name> onto <new-AOSP-tag>`. Reference the original patch
   name and the new AOSP tag in the commit body.

6. **Update the patch file** in the qalos repo so the next rebase is
   mechanical. Use `git format-patch -1 HEAD` to regenerate the
   unified diff against the current AOSP HEAD, and replace the
   old patch file in the qalos repo.

7. **Update this file** if the recovery procedure has changed in a
   non-obvious way.

## Common rebase hazards

- **SystemServer.java** is refactored often. Look for the
  `InputManagerService` constructor call; our registration block
  sits immediately after the matching `traceEnd()`. If the
  InputManager start has moved, our block must move with it.

- **services.core/Android.bp** rarely changes shape, but the
  `srcs` list is occasionally split into multiple sub-libraries.
  If that happens, the new path needs its own
  `PRODUCT_PACKAGES`-style addition in `device/qalos/qalos_emulator/device.mk`.

- **AndroidManifest.xml** is huge; the closing `</manifest>` is
  the only safe anchor. If you cannot find a stable anchor, fall
  back to a unique nearby string and rebuild the patch.

- **strings.xml** is split across many resource directories
  (values/, values-en-rGB/, etc.). The patch only targets
  `values/strings.xml`; translations are not required for the
  build to succeed.

## When the rebase cost exceeds the value

If a rebase takes more than 1 working day, or if two AOSP releases
in a row have made the patches un-mergeable, fork `frameworks/base`
in `default.xml` and maintain our own copy. Document the fork in
`website/docs/qa-lab-os/decisions.md` as a new D-XXX entry.
