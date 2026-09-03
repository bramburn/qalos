---
id: followup-work
title: Followup work
sidebar_label: Followup work
sidebar_position: 11
description: Bugs, deferred items, and Phase 2 work that v0 explicitly did not ship.
---

# Followup work

What `feat/qa-lab-os-v0` ships, what it intentionally defers, and
what the next branch should pick up. Mirror of
[`AGENTS.md` §8.1](https://github.com/bramburn/qalos/blob/main/AGENTS.md#81-qa-lab-os-v0-followup-work).

## What v0 actually ships

- A `SystemService` in `system_server` that exposes a small
  HTTP/JSON API on `127.0.0.1:9000`. 9 endpoints (health, display,
  screenshot, foreground, tap, type, key, launch, force_stop).
- 3 Python-based patches to upstream AOSP 15 files. The fourth
  patch (which would have added `com/qalos/remotectl/*.java` to
  the `services.core` `srcs:`) turned out to be unnecessary —
  the `services.core-sources` filegroup's `srcs: ["java/**/*.java"]`
  glob already picks up our copied sources.
- A Python client SDK and a mock server. 52 pytest tests, all
  green on Windows + Linux.
- Docusaurus site (this section).
- 4-pass AI review reports under `review/`. 35 of 52 findings
  applied; 15 deferred with a one-line reason.

## Bugs caught by the AOSP-15 download-and-dry-run

The agent performed two 4-pass reviews before this dry-run. Both
missed three real bugs. The dry-run is a 5-minute procedure that
catches what code review cannot:

1. **Download the real upstream files** from
   `https://android.googlesource.com/platform/frameworks/base/+/refs/tags/android-15.0.0_r1/<path>?format=TEXT`
   (base64, no newlines).
2. **Drop them into a fake AOSP working tree** at the right
   relative paths (`frameworks/base/services/core/Android.bp`,
   `core/res/AndroidManifest.xml`, etc.).
3. **Run `check-patches.py` against the tree.** If any patch
   exits non-zero, the anchor is wrong and the patch needs a
   rebase.

The full recipe is in
[`lessons-learned.md`](./lessons-learned). The bugs it caught:

| ID | What was wrong | What we changed |
| --- | --- | --- |
| M-A | `len(sys.argv > 1)` in patch 0004 raises `TypeError` (list > int) | Replaced with `len(sys.argv) > 1` |
| M-B | Mock server's `_parse_query` did not URL-decode; `?width=%20300` arrived as the string `"%20300"` instead of the int `300` | Added `urllib.parse.unquote_plus` before the int parse |
| M-C + S-C | `forceStop` used `ActivityManager.killBackgroundProcesses` which silently fails for foreground apps; the `mActivityManager` field was dead | Wired `forceStopInternal` to `IActivityManager.forceStopPackage` and added the missing imports |
| — | Patch 0001 (`Android.bp srcs`) was unnecessary because the `services.core-sources` filegroup's `srcs: ["java/**/*.java"]` glob already includes our directory | Deleted patch 0001; updated `check-patches.py` and `apply-qalos.sh` to skip the 0001 slot |
| — | Patch 0004 anchored on the static `traceBeginAndSlog` method and a bare `traceEnd();`, but AOSP 15 replaced those with a local `Trace t` instance and `t.traceBegin` / `t.traceEnd` | Rewrote the regex and the inserted block to use the `t.` prefix |
| AIDL wiring | The AIDL file was at `services/core/java/com/qalos/remotectl/IRemoteControl.aidl` but the `services.core-sources` filegroup globs `*.java` only, so the AIDL was never compiled and the build would fail with "cannot find symbol: class IRemoteControl" | Replaced the AIDL with a plain Java interface (`com.qalos.remotectl.IRemoteControl`) in the same package; the service implements it directly, the HTTP server takes it as a parameter. Side effect: removed the `publishBinderService` call and the `enforceCallingPermission` (no Binder means no Binder-level security model). A v1+ that wants Binder can re-introduce the AIDL by moving it to `core/java/android/os/` and patching `frameworks/base/Android.bp`. |
| SELinux policy | A new system service that binds a TCP socket needs `service_contexts`, `service.te`, and `system_server.te` entries. None of these existed in v0; the service would fail at boot with `avc: denied { bind }` in dmesg | Added `device/qalos/qalos_emulator/sepolicy/` with `qalos_remote_control.te` (type definition), `service_contexts` (name → label mapping), and `system_server.te` (allow rules: `self:tcp_socket` for the HTTP bind, `service_manager` for the future Binder publication). Wired via `BOARD_SEPOLICY_DIRS` in `device.mk`. |

After the fix-ups, `check-patches.py` reports `OK` for all three
patches against the real AOSP 15 source. The 52/52 pytest suite
still passes.

## Should-fix items deferred until v1

These came out of the second-pass review on the v0 commit. They
are real but do not block the v0 build or behaviour:

| ID | What | Why deferred |
| --- | --- | --- |
| S-A | `ActivityManager.getLaunchIntentForPackage` is deprecated in API 33+ | The deprecation warning is the only consequence; the call still works. Migrate to `PackageManager.getLaunchIntentForPackage` when v1 introduces any other API 33+ changes. |
| S-B | `Display.getRealSize(Point)` is deprecated in API 30+ | Same: deprecation warning only. Use `WindowManager.getCurrentWindowMetrics().getBounds()` when v1 touches display code. |
| S-D | `getDisplayWidth` + `getDisplayHeight` make two Binder round-trips | Cheap individually but doubled on every display query. Combine into one `getDisplaySize(displayId)` AIDL call returning `Size` when v1 adds more display endpoints. |
| S-E | `Bitmap.compress` runs on the binder thread for 100-200 ms | Move to a worker `ExecutorService` when the screenshot endpoint becomes latency-sensitive. |
| S-F | `MotionEvent.recycle()` is also deprecated in API 28+ | Drop the call (mirroring the `Bitmap.recycle()` fix from v0). |
| S-H | `apply-qalos.sh` silently ignores unknown flags | Add a `*)` default arm to the case statement that prints an error. |
| S-I | Patch 0004's regex still requires the literal `InputManagerService` class name | Broaden the anchor so a future rename (e.g. `InputManagerServiceImpl`) does not break the patch. |

## Deferred review items (v1)

| ID | What | Notes |
| --- | --- | --- |
| F-1.16 | `display_size` cache invalidation on rotation | The client caches the first `/display` response forever. Add a `invalidate_display_size()` method and a max-age on the cache. |
| F-2.3 | per-client rate limit on `/screenshot` | Currently no limit; a misbehaving client can pin a binder thread for 100 ms × N requests. |
| F-2.4 | structured error codes | `IllegalArgumentException.getMessage()` is sent to the client. Replace with a stable `{"code": "...", "message": "..."}` shape; log the full message to logcat. |
| F-3.3 | `HttpApiServer` dispatch table | The switch + if-ladder works but is hard to extend. Replace with a `Map<String, BiConsumer<...>>` populated in the constructor. |
| F-3.6 | `QaLabError.code` and `QaLabError.http_status` fields | The current `QaLabError` is a bare `RuntimeError` subclass. Add structured fields so the agent loop can branch on error class. |

## v1 features (PRD Phase 1.5+)

The original PRD names the following features as "deferred from
v0" but in-scope for v1:

- **`long_press`** — press-and-hold gesture. The v0 has no
  endpoint for it; an agent that needs to trigger a context menu
  currently has to chain a tap + a delayed second tap as a
  workaround.
- **`swipe`** — drag gesture. The v0 has no endpoint.
- **`pinch`** — two-finger zoom gesture. The v0 has no endpoint.
  The implementation needs `MotionEvent` with
  `ACTION_POINTER_DOWN` / `ACTION_POINTER_UP` to handle the second
  pointer; the v0 input plumbing only knows one pointer.
- **LLM agent loop template** — a Python skeleton that takes a
  goal, takes a screenshot, asks an LLM, and executes the answer.
  The agent-developer-guide already documents the recommended
  pattern; a runnable reference would lower the bar for the next
  agent.
- **Multi-device orchestration helpers** — the Python client is
  already thread-safe; a `QALab` orchestrator with a barrier-sync
  helper would close the loop on the PRD's "2-3 phones"
  use case.

## Phase 2 (explicitly deferred per the PRD)

These are not in v0 or v1. They each require a separate feature
branch because they change the trust model or the kernel surface:

- **KernelSU-Next + SuSFS kernel hiding** on a physical Pixel 7
  (or OnePlus / Poco). Adds 2-3 more patches to upstream AOSP.
- **GPS spoofing** via a Smali patch on `services.jar` or a
  custom `LocationProvider` HAL.
- **Play Integrity bypass** via TrickyStore + a keybox from a
  certified device. The legal and ethical posture of this is
  the user's call; the agent will not implement it without
  explicit approval.
- **iOS support** via XCUITest + WebDriverAgent. Requires a Mac
  host, an Apple Developer account, and a re-architecture of the
  Python client to talk to a different transport.
- **Sensor injection** (accelerometer, gyroscope, barometer) for
  the navigation-test rig the user described. Requires a custom
  sensor HAL or a kernel module that hooks the sensor drivers.

## What the next agent should do

1. Pull the v0 branch and run `check-patches.py` against your
   local AOSP 15 checkout. The patches should all report `OK`
   out of the box.
2. If you intend to add `long_press` / `swipe` / `pinch`, do it
   on a new branch `feat/qa-lab-os-v1` based on `main`, not on
   top of `feat/qa-lab-os-v0`. v0 is done; v1 should be a clean
   new PR.
3. If you add a new AIDL method, mirror the same 4-pass review
   + AOSP dry-run cycle. The pattern is documented in
   [`lessons-learned.md`](./lessons-learned).
4. **Do not** mix Phase 1 (gestures, agent loop) with Phase 2
   (kernel hiding, GPS spoofing) in the same branch. The
   diff size and the reviewer cognitive load will explode.

## Tracking

| Phase | Branch | Reviewer burden | Estimated LOC |
| --- | --- | --- | --- |
| v0 (done) | `feat/qa-lab-os-v0` | 4-pass AI review | ~5,000 |
| v1 (gestures + agent loop) | `feat/qa-lab-os-v1` | 4-pass + AOSP dry-run | ~1,500 |
| v1 (multi-device helpers) | fold into v1 | — | ~300 |
| v1 (should-fix cleanup) | fold into v1 | — | ~200 |
| Phase 2 (kernel hiding) | `feat/qa-lab-os-hide` | 4-pass + on-device test | ~2,000 |
| Phase 2 (GPS spoofing) | `feat/qa-lab-os-gps` | 4-pass + on-device test | ~1,000 |
| Phase 2 (Play Integrity) | user-decide | — | TBD |
| Phase 2 (sensor injection) | `feat/qa-lab-os-sensor` | 4-pass + on-device test | ~1,500 |

## See also

- [`v0 plan`](./plan) — what is in scope
- [`decisions log`](./decisions) — opinionated choices
- [`lessons learned`](./lessons-learned) — the 5-min dry-run recipe
- [`review log`](./review-log) — the per-pass reports
