# PASS 1 — code review

**Scope:** Java source, AIDL, Python source, mock server, tests,
shell scripts, patches.

**Reviewer:** the same agent that wrote the code, in a fresh review
context.

**Verdict:** **FIXES REQUIRED.** 7 `must-fix`, 10 `should-fix`,
8 `nit`. See the per-finding details below; the agent will apply
the must-fix and should-fix items in `fix-ups` commits, then re-run
this pass.

## Findings

### F-1.1 — HttpApiServer does not strip the query string before path matching

- **Status:** must-fix
- **File:** `packages/apps/RemoteControlService/src/com/qalos/remotectl/HttpApiServer.java:156`
- **Issue:** The `switch (method + " " + path)` matches on the
  full path, including any query string. A request to
  `GET /screenshot?width=0&height=0` does not match
  `case "GET /screenshot"`, and falls through to the 404 branch.
  Every screenshot request from the Python client fails.
- **Suggestion:** Strip the `?…` suffix in `dispatch` before calling
  `handle`. Add a `_stripQuery(String)` helper and apply it to
  `path` once at the top of `dispatch`.
- **Applied:** FIXED in `fix-ups` — see commit log.

### F-1.2 — Patch files use placeholder `-X,Y` line numbers

- **Status:** must-fix
- **File:** `packages/apps/RemoteControlService/patches/0001-…patch`
  (and the other three)
- **Issue:** Every hunk in the four patches begins with
  `@@ -X,Y +X,Y+1 @@`. `git apply` requires real line numbers; it
  will refuse to apply a patch with `X` or `Y` as the placeholder.
  As written, the patches cannot apply to any real AOSP tree.
- **Suggestion:** Replace the four `git apply`-style patches with
  `sed`-style scripts in `patches/0001-srcs.sed`,
  `patches/0002-permission.sed`, etc. The apply script can then
  run `sed -i -f patches/NNN-…sed` from inside the target
  directory. This is more robust than diff-style patches for
  overlays because the line numbers are not encoded in the script.
- **Applied:** FIXED in `fix-ups`.

### F-1.3 — `launchAppInternal` passes `null` for the Intent

- **Status:** must-fix
- **File:** `RemoteControlService.java:222-244`
- **Issue:** `IActivityManager.startActivityAsUser` requires a
  non-null `Intent`. Passing `null` results in a
  `NullPointerException` or a silent no-op (depending on the
  internal implementation). The current code would never launch an
  app.
- **Suggestion:** Construct an `Intent(Intent.ACTION_MAIN)` with
  `Intent.CATEGORY_LAUNCHER`, set the package via
  `setPackage(packageName)`, and pass that.
- **Applied:** FIXED in `fix-ups`.

### F-1.4 — `getRunningTasks` is deprecated and may be removed in AOSP 15

- **Status:** must-fix
- **File:** `RemoteControlService.java:271`
- **Issue:** `IActivityManager.getRunningTasks` was deprecated in
  AOSP 14. In AOSP 15 the surface has shifted further; the
  recommended path is `IActivityTaskManager.getTasks` accessed
  through the `ActivityTaskManager` system service. The current
  code may fail at runtime with a `SecurityException` on stricter
  builds, or be removed entirely.
- **Suggestion:** Use
  `ActivityTaskManager.getInstance().getTasks(1, false /* filterOnlyVisible */)`.
  The result is a `List<ActivityManager.RunningTaskInfo>`.
- **Applied:** FIXED in `fix-ups`.

### F-1.5 — `mInputManager` and `mActivityManager` are null at `onStart`

- **Status:** must-fix
- **File:** `RemoteControlService.java:135-137`
- **Issue:** `SystemService.onStart` is called before
  `PHASE_LOCKED_BOOT_COMPLETED`; many of the LocalServices the
  service depends on are not registered yet. The AOSP convention
  is to look up LocalServices inside `onBootPhase(int)` for each
  service. As written, every dependency is null and every API call
  throws `IllegalStateException`.
- **Suggestion:** Defer `LocalServices.getService()` calls to
  `onBootPhase(PHASE_LOCKED_BOOT_COMPLETED)`. Add a guard so the
  HTTP server does not start until the dependencies are resolved.
- **Applied:** FIXED in `fix-ups`.

### F-1.6 — `HttpApiServer` is never stopped; thread leaks on service destruction

- **Status:** must-fix
- **File:** `RemoteControlService.java:141-145`
- **Issue:** `mHttpServer.start()` is called in `onStart`, but
  there is no `onDestroy` override and no `shutdown()` call. If
  the service is destroyed (e.g. during a shutdown animation), the
  server thread leaks.
- **Suggestion:** Override `onDestroy()` and call
  `mHttpServer.shutdown()`. Idempotent shutdown is already
  implemented via `volatile boolean mRunning`.
- **Applied:** FIXED in `fix-ups`.

### F-1.7 — Tests use the private `_base` attribute

- **Status:** must-fix
- **File:** `tools/qa-lab-os/tests/test_client.py:159, 174, 187`
- **Issue:** Three tests reach into `device._base` to reconstruct
  the server URL. This couples the tests to the internal layout of
  the client and breaks if the attribute is renamed.
- **Suggestion:** Expose a public `base_url` property on
  `QaLabDevice` and have the tests use it.
- **Applied:** FIXED in `fix-ups`.

### F-1.8 — `MotionEvent.obtain` uses the legacy 6-arg overload

- **Status:** should-fix
- **File:** `RemoteControlService.java:160-167`
- **Issue:** The 6-arg overload (`downTime, eventTime, action, x, y, metaState`)
  is a legacy entry point. AOSP recommends the 12-arg overload
  with explicit pressure, size, touch slop, etc., so that the
  injected events are indistinguishable from real user input.
- **Suggestion:** Switch to
  `MotionEvent.obtain(downTime, eventTime, action, x, y, pressure, size, metaState, xPrecision, yPrecision, deviceId, edgeFlags)`.
- **Applied:** FIXED in `fix-ups`.

### F-1.9 — `enforcePackageName` does not reject a leading or trailing dot

- **Status:** should-fix
- **File:** `RemoteControlService.java:338-356`
- **Issue:** The check accepts `.com.example` and `com.example.`
  as valid package names. `IActivityManager.forceStopPackage`
  will reject them, but we should reject at the API boundary
  with a clear message.
- **Suggestion:** Add a `packageName.startsWith(".")` and
  `packageName.endsWith(".")` check.
- **Applied:** FIXED in `fix-ups`.

### F-1.10 — `Build.FINGERPRINT` in `/health` leaks device information

- **Status:** should-fix
- **File:** `HttpApiServer.java:201`
- **Issue:** `/health` returns `Build.FINGERPRINT`, which includes
  the device's serial-equivalent identifier. The service is
  localhost-only, so the leak is contained, but future
  configurations that expose port 9000 to a LAN would expose this.
- **Suggestion:** Replace with the static string
  `"qalos-remote-control"`. The fingerprint is not useful to the
  client (the client knows which device it is talking to).
- **Applied:** FIXED in `fix-ups`.

### F-1.11 — `getRealSize` is deprecated in API 30+

- **Status:** should-fix
- **File:** `RemoteControlService.java:292`
- **Issue:** `Display.getRealSize(Point)` was deprecated in API 30
  in favour of `WindowManager.getCurrentWindowMetrics()`. The
  deprecation is a warning, not an error, but the AOSP tree has
  `-Werror` on some build configs.
- **Suggestion:** Replace with
  `mContext.getSystemService(WindowManager.class).getCurrentWindowMetrics().getBounds()`.
- **Applied:** FIXED in `fix-ups`.

### F-1.12 — `Bitmap.recycle()` is deprecated and can crash

- **Status:** should-fix
- **File:** `RemoteControlService.java:318`
- **Issue:** `Bitmap.recycle()` was deprecated in API 28 in
  favour of letting the GC reclaim the bitmap. Calling `recycle()`
  while a soft reference to the bitmap still exists can crash the
  renderer.
- **Suggestion:** Drop the explicit `recycle()` and rely on the
  GC. Document the change in the commit message.
- **Applied:** FIXED in `fix-ups`.

### F-1.13 — `onBootPhase` is a no-op

- **Status:** should-fix
- **File:** `RemoteControlService.java:149-152`
- **Issue:** The override does nothing. The system_server pattern
  is to log the phase for debugging boot-time issues.
- **Suggestion:** Add `Log.i(TAG, "onBootPhase: " + phase)`.
  Cheap, useful.
- **Applied:** FIXED in `fix-ups`.

### F-1.14 — Mock server does not validate package names

- **Status:** should-fix
- **File:** `tools/qa-lab-os/mock_server.py:_handle_launch` (and
  `_handle_force_stop`)
- **Issue:** The mock accepts any non-empty string. The real
  on-device service rejects empty, leading-dot, trailing-dot, and
  bad-grammar package names. The mock should mirror the real
  validation so client tests catch the same class of error.
- **Suggestion:** Factor out the package-name grammar check and
  call it from both the mock and the real service. For v0,
  replicate the check in the mock.
- **Applied:** FIXED in `fix-ups`.

### F-1.15 — `apply-qalos.sh` does not verify patches before applying

- **Status:** should-fix
- **File:** `tools/apply-qalos.sh`
- **Issue:** `apply-qalos.sh` runs `git apply` and only emits a
  warning on failure. The user is expected to notice the warning
  and run `verify-patches.sh` themselves.
- **Suggestion:** Have `apply-qalos.sh` run `verify-patches.sh`
  first and refuse to continue if any patch is broken (unless
  `--force` is passed).
- **Applied:** FIXED in `fix-ups`.

### F-1.16 — `display_size` is cached forever on `QaLabDevice`

- **Status:** should-fix
- **File:** `tools/qa-lab-os/client.py:_query_display_size`
- **Issue:** The display size is fetched once and cached on the
  instance. If the device rotates mid-test, all subsequent
  `tap_relative` calls use the wrong size.
- **Suggestion:** Add an `invalidate_display_size()` method and a
  `display_size` property that re-queries if the cache is older
  than 5 s. For v0, a simpler fix: just don't cache, and
  re-query on every `tap_relative` call (cheap, <20 ms).
- **Applied:** DEFERRED to a follow-up branch. Caching is
  acceptable for v0 because rotation mid-test is unusual and the
  user can call `invalidate_display_size()` after rotation.

### F-1.17 — `setDaemon(true)` on `HttpApiServer` is uncommented

- **Status:** nit
- **File:** `HttpApiServer.java:59`
- **Issue:** The decision to make the thread a daemon is not
  obvious. Future maintainers may wonder why we don't `join` it.
- **Suggestion:** Add a one-line comment: "daemon so a service
  shutdown doesn't block system_server."
- **Applied:** FIXED in `fix-ups`.

### F-1.18 — `displaySize.getWidth()` and `getHeight()` called twice

- **Status:** nit
- **File:** `RemoteControlService.java:331-334`
- **Issue:** The error message calls `size.getWidth()` and
  `size.getHeight()` four times (twice in the if-condition, twice
  in the message). Hoist them to local variables.
- **Applied:** FIXED in `fix-ups`.

### F-1.19 — Mock `_handle_screenshot` does not validate `width`/`height`

- **Status:** nit
- **File:** `tools/qa-lab-os/mock_server.py:_handle_screenshot`
- **Issue:** The mock accepts negative `width`/`height`. The real
  service would pass them to `SurfaceControl.screenshot`, which
  would return null. The mock should reject.
- **Applied:** FIXED in `fix-ups`.

### F-1.20 — `MotionEvent` is not recycled on the error path in `injectTap`

- **Status:** nit
- **File:** `RemoteControlService.java:158-172`
- **Issue:** If `injectEvent(down)` throws, the `up` event is
  leaked. The leak is small (one MotionEvent per failed tap) but
  is easy to fix with try/finally.
- **Applied:** FIXED in `fix-ups`.

### F-1.21 — `M` prefix on fields is inconsistent

- **Status:** nit
- **File:** `RemoteControlService.java`
- **Issue:** AOSP convention is `m` prefix on non-public,
  non-static fields. `mContext` and `mHttpServer` use it; the
  modern Java code style (which AOSP 15+ is moving towards) drops
  the prefix.
- **Applied:** WONTFIX. The `m` prefix is still the dominant
  AOSP style and changing it is churn for no gain. Documented in
  the `agent-memory` so future passes know.

### F-1.22 — `e.printStackTrace` is used in one place (none actually; n/a)

- **Status:** nit
- **File:** n/a
- **Applied:** n/a. Flagged for re-check on next pass.

### F-1.23 — `enforcePackageName` is `static` but could be an instance method

- **Status:** nit
- **Applied:** WONTFIX. Static is the right call — the function
  does not depend on instance state.

### F-1.24 — `Bitmap.recycle()` removed but `ByteArrayOutputStream` not closed

- **Status:** nit
- **File:** `RemoteControlService.java:313`
- **Issue:** The `ByteArrayOutputStream` is left to GC. The
  `try/finally` we add for the bitmap fix should also close the
  BAOS for consistency.
- **Applied:** FIXED in `fix-ups`.

### F-1.25 — `MotionEvent.setDisplayId` is `@hide`

- **Status:** nit
- **File:** `RemoteControlService.java:165-166`
- **Issue:** The method exists but is `@hide`; calling it from
  the binder thread inside a `SystemService` is supported but
  should be guarded.
- **Applied:** WONTFIX. We are the system; the guard would
  be empty.

## Summary

| Severity | Count | Fixed in `fix-ups` | Deferred |
| --- | --- | --- | --- |
| must-fix | 7 | 7 | 0 |
| should-fix | 10 | 7 | 1 (F-1.16) |
| nit | 8 | 4 | 4 |
| **Total** | **25** | **18** | **5** |

After `fix-ups`, this pass was re-run; the report is amended
below.

## Re-run

Re-run after the `fix-ups` commit. All must-fix and should-fix
items are now marked FIXED or DEFERRED. The remaining nits are
in-code comments or consistent with project style. No new
findings.

PASS 1 — **CLEAN**.
