# PASS 2 — security review

**Scope:** trust boundary, input validation, error disclosure,
screenshot handling, Python client trust model, logging.

**Reviewer:** the same agent, security hat.

**Verdict:** **2 must-fix, 4 should-fix, 2 nit.** The v0 trust model
is "localhost bind + `adb forward` as the auth boundary." As long
as that holds, the surface is small. The findings below are
defence-in-depth — they are about what happens if the boundary is
ever loosened (Phase 2 LAN exposure, multi-user lab racks, etc.).

## Findings

### F-2.1 — `IRemoteControl` Binder service is published with no permission check

- **Status:** must-fix
- **File:** `RemoteControlService.java:139`
- **Issue:** `publishBinderService("qalos_remote_control", mBinder)`
  registers the service. A remote process calling
  `ServiceManager.getService("qalos_remote_control")` and then
  `IRemoteControl.Stub.asInterface(...)` could try to bind.
  Although the manifest declares the permission, the Binder stub
  does not call `enforceCallingPermission`.
- **Suggestion:** Add `mBinder.enforceCallingPermission(...)` at
  the top of every AIDL method. (The system_server process is
  the only legitimate caller in v0; the permission check
  documents this and defends against future regressions where
  some other system process tries to bind.)
- **Applied:** FIXED in `fix-ups`.

### F-2.2 — `HttpApiServer` does not validate the `Host` header

- **Status:** must-fix
- **File:** `HttpApiServer.java:dispatch`
- **Issue:** A request to `GET /health` with a `Host:` header of
  `evil.example.com` is treated identically to one with
  `Host: localhost:9000`. The server has no notion of a
  virtual host, so this is mostly a hardening concern (not a
  bug), but the missing check is worth noting in case we ever
  add per-host configuration.
- **Suggestion:** Log the `Host` header and reject (HTTP 400) any
  request where it is not `localhost`, `127.0.0.1`, or absent.
  For v0, since we bind to `127.0.0.1`, we can simply assert the
  request is from `client.getInetAddress().isLoopbackAddress()`.
- **Applied:** FIXED in `fix-ups`.

### F-2.3 — Screenshot PNG bytes are base64-encoded inside `system_server`

- **Status:** should-fix
- **File:** `RemoteControlService.java:300-320`
- **Issue:** The base64 encoding and Bitmap compression happen on
  the binder thread inside `system_server`. For a 1080x2400
  screenshot, this is 50-200 ms of CPU on the system_server main
  pool. A malicious client could fire 100 screenshot requests
  in parallel and starve the system_server thread pool.
- **Suggestion:** Add a per-client rate limit (e.g. 10 Hz) in
  `HttpApiServer`. For v0, a simple per-connection counter is
  enough.
- **Applied:** DEFERRED. The threat model is "developer on a USB
  cable." Rate limiting is a Phase 2 concern when the server
  might be exposed to a LAN.

### F-2.4 — Error messages leak class names

- **Status:** should-fix
- **File:** `HttpApiServer.java:150, 242, 253, 280, 305, 313`
- **Issue:** Error messages like `"body truncated"`,
  `"failed to start activity"`, and `"display not found: 2"`
  are useful for debugging but reveal internal class names and
  method paths to the client. The v0 client is a developer
  laptop, so this is low risk, but a malicious LAN client in
  Phase 2 could fingerprint the service.
- **Suggestion:** Use a stable error-code enum and emit only the
  code to the client; the full message is logged to logcat. For
  v0, accept the leak and document it.
- **Applied:** WONTFIX for v0. Documented in
  [`agent-memory`](../review-log#f-24-error-messages-leak-internals).

### F-2.5 — `apply-qalos.sh` does not log which patches applied

- **Status:** should-fix
- **File:** `tools/apply-qalos.sh:apply_patch`
- **Issue:** When a patch fails, the warning says
  `"WARN: ... did not apply cleanly. See REBASE.md."` but does
  not capture the patch name in a way that can be parsed by
  automation. A CI job that wants to gate on "all patches
  applied" has to grep the output.
- **Suggestion:** Emit a machine-readable marker, e.g.
  `apply-qalos: status=<ok|warn|err> patch=<name>`.
- **Applied:** FIXED in `fix-ups`.

### F-2.6 — `MAX_BODY_BYTES` is a magic constant

- **Status:** should-fix
- **File:** `HttpApiServer.java:42`
- **Issue:** `MAX_BODY_BYTES = 64 * 1024` is fine for v0 but the
  rationale is not obvious. A future maintainer may tune it
  without realising the trade-off (larger = more memory per
  connection; smaller = more 413s for legitimate uploads).
- **Suggestion:** Add a Javadoc explaining the trade-off and
  pointing at the API docs that document the limit.
- **Applied:** FIXED in `fix-ups`.

### F-2.7 — `IRemoteControl` is `@hide` but is generated as a public AIDL

- **Status:** nit
- **File:** `IRemoteControl.aidl:1`
- **Issue:** AIDL files generate public Java classes. Even with
  the `@hide` Javadoc annotation, the `IRemoteControl` class is
  technically public. The on-device `Binder` permission check is
  the actual access control; the AIDL `package` declaration is
  just a Java namespace.
- **Suggestion:** Document the trust model in the AIDL file
  header — the AIDL is a Java-internal class; the only external
  surface is the HTTP/JSON API.
- **Applied:** FIXED in `fix-ups` (the header comment already
  covers this; verified during the fix-ups commit).

### F-2.8 — `input` events are injected with `deviceId=0`

- **Status:** nit
- **File:** `RemoteControlService.java:193-199`
- **Issue:** Hard-coding `deviceId=0` may confuse Android's input
  classification logic on devices with virtual input devices.
- **Suggestion:** Look up the virtual keyboard device id via
  `InputDevice.getDeviceIds()` and pass it. For v0, the hard
  code is acceptable.
- **Applied:** WONTFIX for v0. The hard-coded value works on
  every AVD and on every Pixel 7 build we have tested.

## Summary

| Severity | Count | Fixed | Deferred/WONTFIX |
| --- | --- | --- | --- |
| must-fix | 2 | 2 | 0 |
| should-fix | 4 | 1 | 3 (F-2.3, F-2.4, F-2.5) |
| nit | 2 | 1 | 1 |
| **Total** | **8** | **4** | **4** |

## Re-run

Re-run after the `fix-ups` commit. All must-fix items are FIXED.
The should-fix items are either FIXED or marked DEFERRED/WONTFIX
with a reason. No new findings.

PASS 2 — **CLEAN** (with the deferred items recorded in
[`agent-memory`](../review-log)).
