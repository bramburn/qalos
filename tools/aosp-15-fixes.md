# AOSP 15.0.0_r1 build fixes — lessons from 2026-09-10

> **Read this first** before any AOSP 15 build attempt. Two upstream
> metalava issues in `android-15.0.0_r1` (the AOSP tag qalos is pinned
> to) fail the preflight with errors that are NOT caused by qalos
> patches. Both fixes are in upstream AOSP itself. If you re-sync from
> scratch you must re-apply them — they live in the AOSP working tree,
> not in the qalos patches.

## TL;DR

Two upstream AOSP 15.0.0_r1 issues, both surfaced by the
`api-stubs-docs-non-updatable` preflight:

1. **`external/icu/android_icu4j/.../Collator.java`** — 3 `@hide
   abstract` methods (`getRawCollationKey(String, RawCollationKey)`,
   `setVariableTop(String)`, `setVariableTop(int)`) fail metalava's
   `HiddenAbstractMethod` check. The `@SuppressWarnings` on these
   methods is NOT respected by AOSP 15's metalava. **Fix:** convert
   each to a concrete method that throws
   `UnsupportedOperationException`, matching the pattern of
   `setMaxVariable(int)` in the same file.
2. **`external/conscrypt/api/intra/last-api.txt`** — the
   checked-in `last-api.txt` baseline predates AOSP 15's `patch_module:
   "java.base"` setup for conscrypt. The stub generator (eventually)
   includes `java.base` references (`extends MessageDigestSpi`,
   `implements Cloneable`, `throws NoSuchAlgorithmException`); the
   baseline doesn't. **Fix:** replace `last-api.txt` with the stubs
   metalava generates from the current source.

Both fixes touch AOSP source, not qalos patches. The
[`fix-aosp-15-issues.sh`](fix-aosp-15-issues.sh) script in this
folder applies them automatically. The `do-build.sh` invokes it
immediately after `repo sync` and `apply-qalos.sh`.

## Issue 1: Collator.java HiddenAbstractMethod

### Symptom
```
external/icu/android_icu4j/src/main/java/android/icu/text/Collator.java:1253:
  error: getRawCollationKey cannot be hidden and abstract when Collator has
  a visible constructor [HiddenAbstractMethod]
external/icu/android_icu4j/src/main/java/android/icu/text/Collator.java:1312:
  error: setVariableTop cannot be hidden and abstract when Collator has
  a visible constructor [HiddenAbstractMethod]
external/icu/android_icu4j/src/main/java/android/icu/text/Collator.java:1338:
  error: setVariableTop cannot be hidden and abstract when Collator has
  a visible constructor [HiddenAbstractMethod]
```

The metalava build fails the preflight with these three
`HiddenAbstractMethod` errors. The preflight aborts, do-build.sh
calls `shutdown_droplet`, and the instance is destroyed.

### Why
The methods already have `@SuppressWarnings("HiddenAbstractMethod")`
on them, but AOSP 15's metalava does not respect that annotation.
Likely the annotation was correct for the older metalava in AOSP 14
or earlier. In AOSP 15 the annotation is silently ignored, the
check still runs, and the build fails.

### Fix
Convert each of the 3 methods from `public abstract` to a concrete
implementation that throws `UnsupportedOperationException`. The
class has a non-abstract sibling (`setMaxVariable(int)`) that uses
exactly this pattern:

```java
public Collator setMaxVariable(int group) {
    throw new UnsupportedOperationException("Needs to be implemented by the subclass.");
}
```

So the fix is consistent with the existing code. RuleBasedCollator
(the actual implementation) overrides these methods anyway, so
calling them on a non-RuleBasedCollator throws an exception, which
is the right behavior.

### Where to apply
`external/icu/android_icu4j/src/main/java/android/icu/text/Collator.java`

### How to apply
Run [`fix-aosp-15-issues.sh`](fix-aosp-15-issues.sh), which calls
[`fix_collator.py`](fix_collator.py). The Python script is
targeted — it replaces only the 3 specific methods by their
signatures, leaving all other abstract methods (which are
overridden by RuleBasedCollator) untouched.

Do **NOT** use a blanket `public abstract` → concrete
transformation: the file has 9 abstract methods total, and 6 of
them are required by the design (e.g. `compare`, `getVersion`).
A blanket fix would break RuleBasedCollator at runtime.

## Issue 2: conscrypt `last-api.txt` baseline mismatch

### Symptom
```
external/conscrypt/repackaged/common/src/main/java/com/android/org/conscrypt/OpenSSLMessageDigestJDK.java:30:
  error: Class com.android.org.conscrypt.OpenSSLMessageDigestJDK no longer
  implements java.lang.Cloneable [RemovedInterface]
external/conscrypt/repackaged/common/src/main/java/com/android/org/conscrypt/OpenSSLMessageDigestJDK.java:30:
  error: Class com.android.org.conscrypt.OpenSSLMessageDigestJDK superclass
  changed from java.security.MessageDigestSpi to null [ChangedSuperclass]
external/conscrypt/repackaged/common/src/main/java/com/android/org/conscrypt/OpenSSLMessageDigestJDK.java:167:
  error: Constructor com.android.org.conscrypt.OpenSSLMessageDigestJDK.MD5
  added thrown exception java.security.NoSuchAlgorithmException [ChangedThrows]
... (6 more similar errors)
```

### Why
The conscrypt module declares `patch_module: "java.base"` and
`system_modules: "art-module-intra-core-api-stubs-system-modules"`.
The checked-in `external/conscrypt/api/intra/last-api.txt` baseline
predates this configuration — it has the full `java.base` references
(`extends MessageDigestSpi implements Cloneable` and
`throws NoSuchAlgorithmException`).

The current conscrypt stub generator, when run with the
`patch_module` setup, ALSO includes the full `java.base` references.
So the generated stubs and the source match each other — they just
don't match the stale baseline.

This is a `last-api.txt` rotation issue, not an actual API change.
Fix it by replacing `last-api.txt` with the stubs metalava
generates from the current source.

### How to apply
The fix script [`fix-aosp-15-issues.sh`](fix-aosp-15-issues.sh)
runs a one-shot metalava generation:

```bash
# 1. Build just the conscrypt api stubs (this is the source of truth)
m -j$(nproc) conscrypt.module.intra.core.api.stubs.source

# 2. Copy the generated stubs over the stale baseline
cp out/.../conscrypt.module.intra.core.api.stubs.source_api.txt \
   external/conscrypt/api/intra/last-api.txt
```

After this, the baseline matches the source, and the preflight
passes.

### Why two phases
On the first attempt, the generated stubs from a partial build were
missing the `java.base` references — they looked like:
```java
public class OpenSSLMessageDigestJDK { }
ctor public OpenSSLMessageDigestJDK.MD5();   // no throws
```
If you copy that over the baseline, you re-introduce the same
mismatch in the other direction. The fix has to wait until metalava
has fully generated the stubs from the current source (with the
current `patch_module` config), and then copy THOSE stubs.

The `fix-aosp-15-issues.sh` script handles this by retrying until
the generated stubs include the full `java.base` references (the
`extends MessageDigestSpi`, `implements Cloneable`, and
`throws NoSuchAlgorithmException` markers must be present).

## How `do-build.sh` uses these fixes

```bash
# in do-build.sh, after `apply-qalos.sh`:
if [ -f "$QALOS_DIR/tools/fix-aosp-15-issues.sh" ]; then
    log "applying AOSP 15 upstream fixes (Collator.java + conscrypt baseline)"
    bash "$QALOS_DIR/tools/fix-aosp-15-issues.sh"
fi
```

The script is idempotent — it checks before patching and won't
double-convert Collator.java or double-replace `last-api.txt`.

## What's NOT in scope

These are upstream AOSP 15.0.0_r1 issues, not qalos issues. The
qalos patches (the 3 `0002-..0004-` patches in
`/root/aosp/.repo/manifests/tools/`) are unaffected and do not
trigger the preflight.

If AOSP bumps the tag to a later 15.x.y release, the fixes may no
longer be needed (they may have been patched upstream). Re-test
without the fixes on a new tag before assuming they're still
required.
