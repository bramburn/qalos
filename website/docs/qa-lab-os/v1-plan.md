---
id: v1-plan
title: v1 plan
sidebar_label: v1 plan
sidebar_position: 12
description: Phase 1 of QA Lab OS — open the API to any network, wire screenshot, add gestures, ship structured errors. Phase 2 (GMS mimicry) stays out of this branch.
---

# QA Lab OS — v1 plan

> **Status: draft pending four user decisions (see §6).** This is the
> concrete shape of `feat/qa-lab-os-v1`. GMS mimicry and Play Integrity
> are explicitly out of scope for this branch — they ship on a separate
> `feat/qa-lab-os-v2-gms` branch per
> [`followup-work.md`](./followup-work.md#phase-2-explicitly-deferred-per-the-prd).

## What v1 ships

`feat/qa-lab-os-v1` builds on top of `feat/qa-lab-os-v0` (already merged
into `main`). The v0 service binds only to `127.0.0.1:9000` and is
limited to 9 endpoints, no screenshot, no gestures. v1 lifts all three
limits.

| Layer | Deliverable | Why |
| --- | --- | --- |
| HTTP server | Bind to `0.0.0.0:9000` when `qalos.remote_ctl.bind_local_only=false`; bearer-token auth on every non-loopback request | Use case is the workstation + emulator on different subnets (Docker, WSL2, VPN) or behind a NAT (Tailscale) |
| Token auth | Random 32-byte hex token generated on first boot, persisted to `/data/local/tmp/qalos_token`, retrieved once via `adb shell cat`, passed as `Authorization: Bearer <token>` | Same auth strength as `adb forward` without the ADB hop; no IP whitelist to maintain |
| Screenshot | `android.window.ScreenCapture.captureDisplay()` with `CountDownLatch` on a worker thread; base64-encoded PNG returned synchronously | The one endpoint every QA flow actually needs |
| Gestures | `POST /long_press`, `POST /swipe`, `POST /pinch` | The three calls the v0 "tap-only" workaround chains; pinch needs 2-pointer `MotionEvent` plumbing |
| Error codes | Replace `e.getMessage()` leaks with `{"code": "...", "message": "...", "field": "..."}` | Agents can branch on `code`; humans can grep on `message` |
| Dispatch table | `Map<String, BiConsumer<...>>` in the HTTP server constructor | Replaces the switch + if-ladder per `followup-work.md` F-3.3; extensible without recompiling |
| Tailscale install script | `tools/qa-lab-os/install-tailscale.sh` (one-time, runs on the device) | A stable `*.tailxyz.ts.net` hostname works from anywhere — no port forwarding, no IP whitelists |
| Dead-code removal | Delete `device/qalos/qalos_emulator/overlay_frameworks/frameworks/base/core/java/com/android/{api,auth,app,os,internal}/` (6 files) | They reference `android.os.LayeredRuntime` which does not exist in AOSP 15 — aspirational stubs left over from an earlier sketch |

**v1 does NOT include**: Play Integrity bypass, MicroG / GMS mimicry,
keybox handling, kernel hiding, GPS spoofing, sensor injection, iOS
support. Those are Phase 2 on separate branches per
`followup-work.md §"Phase 2"`.

## Why a separate branch

Three reasons, all from `followup-work.md`:

1. **No-mixing rule.** "**Do not** mix Phase 1 (gestures, agent loop)
   with Phase 2 (kernel hiding, GPS spoofing) in the same branch. The
   diff size and the reviewer cognitive load will explode." — direct
   quote from `followup-work.md §"What the next agent should do" item 4`.
2. **Branch protection.** The tracking table at the bottom of
   `followup-work.md` records `feat/qa-lab-os-v1` as "4-pass + AOSP
   dry-run, ~1,500 LOC". The GMS branch is a separate row.
3. **Different trust model.** GMS mimicry changes the *integrity
   posture* of the device (apps now see a Play-authorized identity).
   That is a security review, not a feature review. Mixing it with
   benign API expansion makes both reviews weaker.

## Endpoint delta from v0 to v1

| Method | Path | v0 status | v1 change |
| --- | --- | --- | --- |
| GET | `/health` | 200 plain JSON | unchanged |
| GET | `/display` | 200 plain JSON | unchanged |
| GET | `/screenshot` | 501 Not Implemented | **wired** via `ScreenCapture.captureDisplay()` |
| GET | `/foreground` | 200 plain JSON | unchanged |
| POST | `/tap` | 200 | unchanged |
| POST | `/type` | 200 | unchanged |
| POST | `/key` | 200 | unchanged |
| POST | `/launch` | 200 | unchanged |
| POST | `/force_stop` | 200 | unchanged |
| POST | `/long_press` | not in v0 | **new** — `{x, y, duration_ms}` |
| POST | `/swipe` | not in v0 | **new** — `{x1, y1, x2, y2, duration_ms}` |
| POST | `/pinch` | not in v0 | **new** — `{x1, y1, x2, y2, scale, duration_ms}` |
| Any | any | 400 with leaked `getMessage()` | **new** — `{"code": "...", "message": "...", "field": "..."}` |
| Any | any (non-loopback, missing/wrong token) | not gated | **new** — 401 `UNAUTHORIZED` |

## Implementation order

The work packages below are ordered so each one is independently
buildable and reviewable. Each package ends at a green `pytest` +
`check-patches.py` checkpoint.

### Package 1 — token auth + bind-all-interfaces (~80 net new LOC)

1. Add `qalos.remote_ctl.bind_local_only` prop reader in
   `RemoteControlService.onStart()`. Default is `true` (matches v0
   behaviour; the emulator already shipped with this).
2. Token generator: on first boot, if
   `/data/local/tmp/qalos_token` does not exist, write a
   `SecureRandom`-generated 32-byte hex string (64 chars). Set
   permissions to `0644` so any `adb shell` user can read it.
3. HTTP server reads the token from disk at startup. When the bind
   flag is false, every request without a valid
   `Authorization: Bearer <token>` gets 401 with
   `{"code": "UNAUTHORIZED", ...}`.
4. Loopback guard at `HttpApiServer.java` line 132 stays as
   defence-in-depth; it only matters when the bind flag is true
   anyway.

### Package 2 — screenshot wiring (~120 net new LOC)

1. Replace the `UnsupportedOperationException` stub in
   `RemoteControlService.screenshotBase64Internal()` with a real
   implementation.
2. **`ScreenCapture.captureDisplay(displayId)` is synchronous on
   AOSP 15.** No `CountDownLatch`, no `Executor`. The call returns a
   `ScreenshotHardwareBuffer` directly on the calling thread. The
   HTTP handler thread blocks for the duration of the capture
   (~50 ms in practice on an emulator). See D-018.
3. Inside the implementation:
   `ScreenshotHardwareBuffer` → `Bitmap.wrapHardwareBuffer(...)` →
   optional aspect-ratio-preserving
   `Bitmap.createScaledBitmap(...)` if the caller asked for a
   specific `width`/`height` → `Bitmap.compress(PNG, 100, ...)` →
   `Base64.encodeToString(..., NO_WRAP)`. The `quality` parameter is
   accepted (1–100) but ignored — PNG is lossless.
4. No new permission or manifest entry — `ScreenCapture` is callable
   from `system_server` without an extra permission grant in AOSP 15.

### Package 3 — gestures (~180 net new LOC)

1. Add to `IRemoteControl`: `longPress(x, y, durationMs, displayId)`,
   `swipe(x1, y1, x2, y2, durationMs, displayId)`,
   `pinch(x1, y1, x2, y2, scale, durationMs, displayId)`.
2. `longPress`: schedule ACTION_DOWN, sleep `durationMs`, ACTION_UP.
3. `swipe`: linear-interpolate N points between start and end over
   `durationMs`; emit ACTION_MOVE per point.
4. `pinch`: ACTION_DOWN + ACTION_POINTER_DOWN with two pointers,
   interpolated per-frame `pointerCoords[]`, ACTION_POINTER_UP +
   ACTION_UP. Uses `MotionEvent.obtain(downTime, eventTime, action,
   pointerCount, pointerProps, pointerCoords, ...)`.
5. HTTP layer parses the JSON bodies, validates ranges (non-negative
   coords, `durationMs > 0`, `scale > 0`).

### Package 4 — structured errors + dispatch table (~50 net new LOC)

1. Replace `writeError(out, status, message)` with
   `writeError(out, status, "CODE_NAME", message, field?)`.
2. New `RequestHandler` interface;
   `Map<String, RequestHandler> HANDLERS = Map.ofEntries(...)` in
   constructor.
3. `handle()` becomes `HANDLERS.get(method + " " + path).apply(...)`;
   404 becomes `"no such endpoint"` with `code = "NOT_FOUND"`.

### Package 5 — Tailscale + dead-code removal (~−400 net LOC)

1. Add `tools/qa-lab-os/install-tailscale.sh`: download the latest
   stable Tailscale APK from `pkgs.tailscale.com` (resolved via the
   `?mode=json` manifest), `adb install -r` it, start
   `com.tailscale.ipn/.MainActivity`, and either pass
   `--authkey=<KEY>` for headless auth or print the manual
   `tailscale up` URL. The script also reports the device's
   Tailscale IP and a ready-to-run `curl` example for the
   bearer-token API.
2. Dead-code removal — verified already absent on disk
   (`overlay_frameworks/` directory does not exist). Nothing to
   remove; tracked as a no-op.

### Package 6 — verify with the dry-run

The mandatory 5-minute recipe from
[`lessons-learned.md`](./lessons-learned.md#the-5-min-download-and-dry-run-recipe):

```powershell
python3 packages/apps/RemoteControlService/patches/check-patches.py .tmp/aosp-15-tree
foreach ($p in Get-ChildItem packages/apps/RemoteControlService/patches/000*.py) {
  python3 $p.FullName .tmp/aosp-15-tree
}
```

If any patch exits non-zero, the anchor is wrong and the patch needs a
rebase. This is non-negotiable — it caught the v0 M-A, M-B, M-C bugs
that two AI review passes missed.

## Decisions log additions

This plan introduces five new decisions for `decisions.md`:

- **D-009** — Bearer-token auth (replaces `adb forward`-only model
  from v0).
- **D-010** — Token stored at `/data/local/tmp/qalos_token`, mode
  `0644`, retrieved once via `adb shell cat` (the
  `/data/local/tmp/` path is ADB-writable, world-readable).
- **D-011** — Tailscale for cross-WAN reach (vs mDNS, vs reverse
  tunnel). Userland WireGuard; no root; runs as a privileged system
  app; gives a stable `*.tailxyz.ts.net` hostname.
- **D-012** — `feat/qa-lab-os-v2-gms` is a separate branch for GMS
  mimicry.
- **D-013** — Remove the 6 overlay-framework stub files
  (`api/`, `auth/`, `app/`, `os/`, `internal/` namespaces under
  `overlay_frameworks/`) — they reference
  `android.os.LayeredRuntime` which does not exist in AOSP 15.

D-014 (Play Integrity keybox posture) and D-015 (MicroG build path)
are **deferred to v2-gms** per `followup-work.md §"Phase 2"`.

## Pending user decisions (gate v1 start)

1. **Token storage path** — `/data/local/tmp/qalos_token` is
   world-readable (ADB shell can `cat` it). Acceptable for a QA
   image, or do you want a tighter path / permissions?
   - **Resolved 2026-09-20** — accepted as designed. Mode 0644,
     ADB-readable. The auth model is "anyone on the device network
     with the bearer token can drive the API", not "only ADB can
     drive the API" — there is no security boundary being lost.
2. **Cross-WAN transport** — Tailscale (recommended; gives a stable
   hostname), mDNS (LAN-only), or reverse SSH tunnel (depends on a
   reachable VPS)?
   - **Resolved 2026-09-20** — Tailscale. Install script at
     `tools/qa-lab-os/install-tailscale.sh`.
3. **Overlay hooks removal** — Confirm removing the 6 dead stubs
   under `overlay_frameworks/` as dead code, or keep them as
   placeholders for future Phase 2 work?
   - **Resolved 2026-09-20** — stubs already verified absent
     (`overlay_frameworks/` directory does not exist on disk). No
     removal needed.
4. **Screenshot async pattern** — `CountDownLatch` in the synchronous
   `screenshotBase64Internal()` (blocks a per-connection thread for
   ~50 ms; keeps the API unchanged) vs `CompletableFuture` (cleaner
   async; requires updating `IRemoteControl` and the dispatch
   layer)?
   - **Resolved 2026-09-20** — `ScreenCapture.captureDisplay(int)`
     is **synchronous** on AOSP 15 (no `CountDownLatch`,
     no `Executor` needed). The implementation calls it directly on
     the per-connection HTTP handler thread. This blocks for ~50 ms
     per call; documented as D-018.
5. **Phase 2 GMS material in `qalos_emulator.mk`** — debug-hook
   properties (`ro.config.debug.api_hook=1`, etc.) were reverted
   from this branch; they belong on `feat/qa-lab-os-v2-gms` only,
   never on v1.
   - **Resolved 2026-09-20** — kept off v1; tracked for the
     v2-gms branch.

## Approximate LOC delta

| Area | +Lines | -Lines |
| --- | --- | --- |
| Token auth + bind config | ~80 | ~20 |
| Screenshot wiring | ~120 | ~10 |
| Gestures (3 endpoints) | ~180 | 0 |
| Error codes + dispatch table | ~100 | ~60 |
| Tailscale script + docs | ~80 | ~10 |
| Remove dead overlay stubs | 0 | ~400 |
| **Total** | **~560** | **~500** |

Net **~60 LOC added**, against ~1,500 LOC budgeted in
`followup-work.md §"Tracking"`. v1 is intentionally small so the
review cycle stays fast.

## Tracking

| Phase | Branch | Reviewer burden | Estimated LOC |
| --- | --- | --- | --- |
| v0 (done) | `feat/qa-lab-os-v0` | 4-pass AI review | ~5,000 |
| **v1 (this plan)** | **`feat/qa-lab-os-v1`** | 4-pass + AOSP dry-run | **~60 net** |
| v2-gms (deferred) | `feat/qa-lab-os-v2-gms` | 4-pass + on-device test | TBD |
| Phase 2 (kernel hiding) | `feat/qa-lab-os-hide` | 4-pass + on-device test | ~2,000 |
| Phase 2 (GPS spoof) | `feat/qa-lab-os-gps` | 4-pass + on-device test | ~1,000 |
| Phase 2 (sensor injection) | `feat/qa-lab-os-sensor` | 4-pass + on-device test | ~1,500 |

## See also

- [`v0 plan`](./plan.md) — what was in v0 scope
- [`followup-work.md`](./followup-work.md) — source of the v1 / v2
  split
- [`decisions.md`](./decisions.md) — append-only decision log
- [`lessons-learned.md`](./lessons-learned.md) — the 5-min dry-run
  recipe
