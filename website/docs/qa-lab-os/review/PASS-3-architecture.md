# PASS 3 — architecture review

**Scope:** separation of concerns, testability, dependency
direction, build-system footprint, error-handling consistency, API
ergonomics.

**Reviewer:** the same agent, architecture hat.

**Verdict:** **1 must-fix, 5 should-fix, 4 nit.** The v0 shape is
sound. The findings are about making the package easier to
extend for Phase 2.

## Findings

### F-3.1 — `apply-qalos.sh` does not enforce that the qalos repo is up to date

- **Status:** must-fix
- **File:** `tools/apply-qalos.sh:36-39`
- **Issue:** The script does `git pull --ff-only` in the qalos
  manifest repo before applying, but a non-ff-only pull (e.g.
  the user has local commits) silently falls back to the
  existing checkout. The user then thinks they are running
  `feat/qa-lab-os-v0` HEAD but they are running their local
  branch.
- **Suggestion:** Print a louder error and exit non-zero on a
  failed pull. The script should not silently fall back.
- **Applied:** FIXED in `fix-ups`.

### F-3.2 — Service depends on `Context` but only uses it once

- **Status:** should-fix
- **File:** `RemoteControlService.java:124-125`
- **Issue:** `mContext` is stored but only used to call
  `getSystemService(DisplayManager.class)`. We could store the
  `DisplayManager` directly.
- **Suggestion:** Store `DisplayManager` instead of `Context`.
  Reduces the surface area for misuse.
- **Applied:** FIXED in `fix-ups`.

### F-3.3 — `HttpApiServer.handle` switch is a fall-through for unknown paths

- **Status:** should-fix
- **File:** `HttpApiServer.java:154-191`
- **Issue:** The `switch` matches on `method + " " + path` and
  falls through to a 404 for unknowns. The if-else ladder for
  POSTs duplicates the same idea. A single dispatch table
  (Map<String, BiConsumer<...>>) would be easier to extend.
- **Suggestion:** Replace the switch/if-else with a `Map<String,
  Handler>` populated in the constructor. Each handler takes the
  parsed body and the output stream. This is a v0→v1 cleanup.
- **Applied:** DEFERRED. The switch is fine for v0's 9
  endpoints. Refactor when we add long_press, swipe, pinch.

### F-3.4 — `verify-patches.sh` re-implements the patch-detection logic

- **Status:** should-fix
- **File:** `packages/apps/RemoteControlService/patches/verify-patches.sh`
- **Issue:** The script extracts the target directory from the
  patch header by hand. `git apply` already does this — we
  should let `git apply` work for us and only catch the failure
  exit code.
- **Suggestion:** Simplify: for each patch, do
  `(cd "$dir" && git apply --check "$patch" 2>&1)`. The error
  message is already informative; we do not need to add ours on
  top.
- **Applied:** FIXED in `fix-ups`.

### F-3.5 — The `try/finally` cleanup in `apply-qalos.sh` is not actually try/finally

- **Status:** should-fix
- **File:** `tools/apply-qalos.sh:apply_patch`
- **Issue:** If `git apply` succeeds for patch 1, 2, 3 but
  fails for 4, the first three are already applied. A partial
  application is hard to roll back. The function should use
  `set -e` and a marker-based resume.
- **Suggestion:** Document the partial-apply hazard. Suggest the
  user run `verify-patches.sh` first.
- **Applied:** FIXED in `fix-ups` (added a check at the top of
  apply-qalos.sh that runs verify-patches.sh and refuses to
  continue on any failure unless `--force` is passed).

### F-3.6 — Python client has no `__repr__` on errors

- **Status:** should-fix
- **File:** `tools/qa-lab-os/client.py:QaLabError`
- **Issue:** `QaLabError` is a bare `RuntimeError` subclass with
  no custom `__init__` or `__str__`. The error message
  (`"POST /tap failed: ..."`) is helpful but a structured
  `code` and `http_status` would be more programmatic.
- **Suggestion:** Add `code` (string, e.g. `"bad_request"`) and
  `http_status` (int) fields. For v0, accept the simpler form.
- **Applied:** DEFERRED. The current shape is fine for v0.
  Tracked in agent memory for a follow-up.

### F-3.7 — `displaySize` import in `RemoteControlService` is `android.util.Size`

- **Status:** nit
- **File:** `RemoteControlService.java:283, 304`
- **Issue:** The class uses `android.util.Size` fully-qualified
  inline rather than importing it.
- **Suggestion:** Add the import.
- **Applied:** FIXED in `fix-ups`.

### F-3.8 — `M` prefix on `mInputManager` is misleading

- **Status:** nit
- **File:** `RemoteControlService.java:60-62`
- **Issue:** All three fields use the `m` prefix, but
  `mActivityManager` is an `IActivityManager` (a Binder
  interface) while `mInputManager` is a `LocalService` reference.
  Different lifecycles, same prefix.
- **Applied:** WONTFIX. Same as F-1.21.

### F-3.9 — `verify-patches.sh` exits 0 on a no-op run

- **Status:** nit
- **File:** `verify-patches.sh`
- **Issue:** If the patch dir is empty, the script exits 0 and
  says "All 4 patches apply cleanly." which is technically
  true (vacuously) but misleading.
- **Applied:** FIXED in `fix-ups`.

### F-3.10 — `agent-developer-guide.md` shows a 4-arg `device.key` call but the v0 has 3-arg

- **Status:** nit
- **File:** `website/docs/qa-lab-os/agent-developer-guide.md:124`
- **Issue:** The example shows
  `device.key(action["key_code"], down=action.get("down", True))`
  which is correct. The wording is fine.
- **Applied:** n/a. False alarm during the review.

### F-3.11 — `MotionEvent` recycling is hand-rolled in `injectTap`

- **Status:** nit
- **File:** `RemoteControlService.java:170-171`
- **Issue:** We call `recycle()` on `down` and `up` after
  `injectEvent`. The `try/finally` fix in F-1.20 will make this
  cleaner.
- **Applied:** FIXED in `fix-ups` (folded into the F-1.20 fix).

## Summary

| Severity | Count | Fixed | Deferred/WONTFIX |
| --- | --- | --- | --- |
| must-fix | 1 | 1 | 0 |
| should-fix | 5 | 3 | 2 (F-3.3, F-3.6) |
| nit | 4 | 2 | 2 |
| **Total** | **10** | **6** | **4** |

## Re-run

Re-run after the `fix-ups` commit. All must-fix items are FIXED.
No new findings.

PASS 3 — **CLEAN**.
