---
id: decisions
title: Decisions log
sidebar_label: Decisions
sidebar_position: 3
description: Opinionated, recorded design decisions for QA Lab OS. Append-only.
---

# Decisions log

Append-only. Each entry records a decision, the alternatives considered,
and the rationale. New entries go at the bottom. Earlier entries are
**not** edited; if a decision is reversed, a new entry is added that
links to the old one.

## D-001 — Base: AOSP, not LineageOS

**Decision:** Fork AOSP `android-15.0.0_r1` for QA Lab OS.

**Considered:** LineageOS 22.1 fork (the path sketched in the original
PRD).

**Rationale:** qalos is already an AOSP-manifest overlay. Layering
LineageOS on top would add a second opinion layer (LineageOS UI patches,
settings provider, themes) that we do not consume and that complicates
every AOSP rebases. AOSP + the qalos overlay is a smaller surface to
maintain.

## D-002 — v0 shape: framework service in `system_server`

**Decision:** Ship the Remote Control Service as a system service in
`com.qalos.remotectl`, compiled into `frameworks/base/services/core/`.
Source lives in the qalos overlay and is copied to the AOSP tree by
`tools/apply-qalos.sh`. Targeted patches modify the four upstream AOSP
files that must be touched (SystemServer, AndroidManifest, strings.xml,
services.core/Android.bp).

**Considered:**

| | Privileged system app | Framework service (chosen) |
| --- | --- | --- |
| Files in qalos overlay | ~5 Java files + AndroidManifest.xml | ~5 Java files + AIDL + 5 patches |
| AOSP files modified | none | 4 (SystemServer, AndroidManifest, strings.xml, services.core/Android.bp) |
| AOSP rebase cost | none | ~1 day per AOSP release to rebase the 4 patches |
| Process | `/system/priv-app` (separate from system_server) | `system_server` (same as InputManager, WindowManager) |
| Permissions | `INJECT_EVENTS`, `READ_FRAME_BUFFER` (signature\|privileged) | `REMOTE_CONTROL` (signature\|system) |
| API surface | Same — `InputManager.injectInputEvent`, `SurfaceControl.screenshot` | Same |
| Lifecycle | Own service entry, onStart/onBootPhase | Standard `SystemService` lifecycle |
| Testability | Easy to install standalone | Requires AOSP build |

**Rationale:** The user picked the framework-service path despite the
extra maintenance cost, on the grounds that the "true native" shape is
worth the small rebase burden for a manifest overlay. We mitigate the
rebase cost by:

1. Authoring **small, focused patches** (≤ 10 lines each) so conflicts
   are localised and easy to resolve.
2. Keeping all the **service Java** in the qalos overlay so a rebase
   only touches the 4 framework files.
3. Recording a **rebase runbook** in
   [`build-guide.md`](./build-guide#rebase-runbook) so the procedure
   is mechanical.
4. Capturing every patch with a stable prefix so a `git apply --check`
   pass in CI is enough to confirm a rebase is clean.

If the rebase cost ever exceeds the value (e.g., a major AOSP rewrite
of `SystemServer`), the fallback is to fork `frameworks/base` in
`default.xml` and maintain our own copy.

## D-002a — Package namespace: `com.qalos.remotectl`

**Decision:** Service Java package is `com.qalos.remotectl`. Source
files live in the AOSP tree at
`frameworks/base/services/core/java/com/qalos/remotectl/`. The path
departs from the AOSP convention of `com.android.server.*` because
the package name is the durable identity of our service, and the
path is just a filesystem artefact.

## D-003 — Endpoint: HTTP/JSON, not gRPC

**Decision:** The on-device API is HTTP/JSON, served by an embedded
`ServerSocket` inside the system app.

**Considered:** gRPC (mentioned in the original PRD sketch).

**Rationale:** HTTP/JSON is debuggable with `curl`, language-agnostic
for any future client, and trivial to mock in Python for tests. gRPC
adds a runtime dependency, a code-gen step, and a steeper debug curve
for no gain at v0's scale (one client, ten endpoints).

## D-004 — Default bind: localhost only

**Decision:** The HTTP server binds to `127.0.0.1:9000` by default. The
only way to reach it from another host is `adb forward` (USB or
`adb tcpip` over Wi-Fi) — both of which require ADB-level auth.

**Considered:** Bind to `0.0.0.0` with an IP whitelist and API key.

**Rationale:** Localhost-only removes an entire class of exposure
incidents. The v0 use case (1 user, 1 workstation, 1-3 phones on USB
hubs) does not need LAN access. The whitelist + API key path is a
follow-up for Phase 2.

## D-005 — Agent model: vision-only, x,y coordinates

**Decision:** The agent sees screenshots and emits `x, y` taps. There
is no accessibility-tree or element-ID mode.

**Considered:** Appium-style accessibility IDs.

**Rationale:** Vision-only is LLM-native, robust to UI refactors, and
universal across apps (including WebViews, games, and third-party
apps). Accessibility IDs require building and maintaining an element
library that breaks every release. The PRD's first answer.

## D-005a — v0 API surface: minimal subset

**Decision:** v0 ships the following endpoints, and no others:

| Method | Path | Purpose |
| --- | --- | --- |
| GET | `/health` | liveness check |
| GET | `/display` | `{width, height}` |
| GET | `/screenshot` | PNG, base64 |
| GET | `/foreground` | `{package}` |
| POST | `/tap` | `{x, y, display}` |
| POST | `/type` | `{text}` |
| POST | `/key` | `{key_code, down}` |
| POST | `/launch` | `{package}` |
| POST | `/force_stop` | `{package}` |

**Deferred** (explicit follow-ups, not in v0): `long_press`, `swipe`,
`pinch`. Reasoning per the user: a smaller surface is faster to
review; gestures are easy to add once the base works.

## D-005b — Licensing: Apache-2.0 / MIT split

**Decision:**

- All Java and AIDL source files carry an SPDX `Apache-2.0` license
  header. These files live next to AOSP-derivative code and follow
  the AOSP convention.
- All Python source, the mock server, the test suite, the patch
  scripts, and the Docusaurus docs are MIT, matching the rest of
  qalos.

**Convention:** every source file gets a top-of-file SPDX line in
addition to any per-file copyright. The convention is recorded here
so the AI review (and the human reviewers) can verify it on every
PR by `grep -L "SPDX-License-Identifier" <new files>`.

- Java/AIDL: the SPDX line is a `//` comment on the first or
  second line.
- Python: the SPDX line is the first line of the file, prefixed
  with `#`.
- Shell: the SPDX line is the second line of the file (after the
  `#!/usr/bin/env` shebang), prefixed with `#`.
- Docusaurus markdown: the SPDX line is in the YAML front-matter as
  a comment, or in a top-of-file HTML comment if the file has no
  front-matter.

A PR that introduces a new file without the SPDX line is
`should-fix` per the static-check policy.

## D-006 — Build host: local Linux box (per qalos AGENTS.md)

**Decision:** The v0 AOSP build runs on a local Linux box per the
qalos AGENTS.md "local first" rule. The AVD run is also local.

**Considered:** AVD on Aliyun (via the existing aliyun-build.ps1
pipeline).

**Rationale:** Aliyun costs ~¥7-14 per build and adds 10-15 min of
orchestrator overhead. v0 is a 2-5 min incremental loop. Reserve
Aliyun for the final integration build (Phase 2) once the AOSP build
is settled.

## D-007 — Tests: mock server + pytest, plus AVD smoke on Linux

**Decision:** v0 ships two test layers:

1. **Host-side** (runs anywhere with Python 3.11+): a mock HTTP server
   that pretends to be the on-device API, plus a `pytest` suite that
   exercises the client SDK end-to-end. Runs in CI on every PR.
2. **AVD smoke** (runs on the Linux box only): a single `m`+`emulator`
   pass that verifies the APK is installed and `/health` returns 200.
   Documented in the build guide, not gated in CI.

**Considered:** Running the AOSP build on GitHub Actions.

**Rationale:** The AOSP build is 30-60 min on first run and would burn
the GH Actions free tier in a single run. The existing qalos
`ci.yml` policy is "static checks only" — we honour it.

## D-008 — Static checks: AI 4-pass review, captured in `review/`

**Decision:** v0 is reviewed by the same agent that wrote the code in
4 passes, each producing a markdown report in `qa-lab-os/review/`. Each
finding is tagged `must-fix` / `should-fix` / `nit`. Code is updated
and the report is amended in place so the diff is visible.

**Rationale:** The user explicitly asked for "static check with AI" and
"several reviews." Four passes (code / security / architecture / docs)
is a useful cross-section without overrunning the token budget. The
amended report is the audit trail.

---

(More entries appended below as decisions are made.)
