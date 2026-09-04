---
id: architecture
title: Architecture
sidebar_label: Architecture
sidebar_position: 4
description: How the on-device service and the workstation client fit together.
---

# Architecture

QA Lab OS has two halves: an **on-device service** that runs inside
`system_server`, and a **workstation client** that drives it over
HTTP/JSON.

## Component map

```
┌──────────────────────────────────────────────────────────────────────┐
│ Workstation                                                          │
│                                                                      │
│  ┌────────────────┐    ┌─────────────────────┐    ┌──────────────┐  │
│  │  LLM Agent     │    │  Python Client SDK  │    │ Test Runner  │  │
│  │  (vision-LM)   │◄──►│  (qa_lab_os.client) │◄──►│ (pytest etc) │  │
│  └────────────────┘    └──────────┬──────────┘    └──────────────┘  │
│                                   │                                  │
│                          HTTP/JSON (localhost:9000)                  │
│                          via `adb forward tcp:9000 tcp:9000`         │
└───────────────────────────────────┬──────────────────────────────────┘
                                    │
┌───────────────────────────────────▼──────────────────────────────────┐
│ Android device (or AVD)                                              │
│                                                                      │
│  ┌────────────────────────────────────────────────────────────────┐  │
│  │ system_server process                                          │  │
│  │                                                                │  │
│  │  ┌──────────────────────┐     ┌────────────────────────────┐  │  │
│  │  │ RemoteControlService │────►│ HttpApiServer              │  │  │
│  │  │ (com.qalos.remotectl)│     │ (com.qalos.remotectl)      │  │  │
│  │  │                      │     │                            │  │  │
│  │  │  - InputManagerService.injectInputEvent                    │  │  │
│  │  │  - SurfaceControl.screenshot                               │  │  │
│  │  │  - IActivityManager.*                                      │  │  │
│  │  └──────────────────────┘     └────────────────────────────┘  │  │
│  │           │                              │                     │  │
│  │           ▼                              ▼                     │  │
│  │  ┌───────────────────────────────────────────────────────┐    │  │
│  │  │ AOSP framework (InputManager, WindowManager, etc.)     │    │  │
│  │  └───────────────────────────────────────────────────────┘    │  │
│  └────────────────────────────────────────────────────────────────┘  │
└──────────────────────────────────────────────────────────────────────┘
```

## The on-device service

The service is a single Java package — `com.qalos.remotectl` — with
three source files:

| File | Role |
| --- | --- |
| `IRemoteControl.aidl` | Internal AIDL contract between the service and its HTTP front-end. Not exposed to other apps. |
| `RemoteControlService.java` | A `SystemService` that wires the framework-side dependencies (`InputManagerService`, `IActivityManager`, `DisplayManager`) into the AIDL methods. |
| `HttpApiServer.java` | An embedded HTTP/JSON server on `127.0.0.1:9000`. Translates HTTP requests into in-process calls on the `IRemoteControl.Stub` (no Binder marshalling because both halves run in `system_server`) and renders the results as JSON. |

The service is registered by `SystemServer` immediately after
`InputManagerService` has started. The order matters because
`RemoteControlService` resolves `LocalServices.getService(...)` for
`InputManagerService` and `IActivityManager` in `onBootPhase`, and
both must have been published first. The four Python-based
"patches" (see [`v0 plan`](./plan)) are what put the source into
`frameworks/base/services/core/java/com/qalos/remotectl/` and
register the service.

## The workstation client

The Python client is a single class — `QaLabDevice` — that wraps the
HTTP/JSON surface. It depends on `requests` and `Pillow` only.

For host-side development without an AVD, the `mock_server.py`
module is a pure-Python stand-in for the on-device service. The
test suite (`tools/qa-lab-os/tests/`) runs entirely against the mock
and is CI-friendly.

## The communication boundary

| Layer | Transport | Why |
| --- | --- | --- |
| Workstation → device | `adb forward tcp:9000 tcp:9000` + HTTP/JSON | ADB-level auth; no LAN exposure; the only auth boundary v0 needs (D-004). |
| Inside the device | `ServerSocket(127.0.0.1, 9000)` → AIDL calls | All in-process; no marshalling across Binder because the AIDL caller is in `system_server`. |

## Trust and capabilities

- The HTTP server is the only network surface. It binds to
  `127.0.0.1` (D-004). It is not visible from the device's Wi-Fi
  network; reaching it requires `adb forward`, which in turn
  requires USB-debugging-level access.
- The AIDL methods are `signature` protected by the
  `android.permission.REMOTE_CONTROL` permission. The service runs
  in `system_server`, which self-binds without an explicit grant.
- External apps that try to bind to `IRemoteControl` will be
  rejected by the permission check.

## Lifecycle

```
repo init + repo sync       # 1-2 hours on a warm cache
  └── tools/apply-qalos.sh  # ~1 minute; copies source + applies 4 patches
       └── source build/envsetup.sh
            └── lunch qalos_emulator-userdebug
                 └── m     # 2-6 hours first build, 2-5 min incremental
                      └── emulator -no-snapshot -writable-system
                           └── adb forward tcp:9000 tcp:9000
                                └── curl http://localhost:9000/health
```

See [`build-guide.md`](./build-guide) for the full procedure and the
rebase runbook.

## What's not in v0

- **Long press, swipe, pinch.** Deferred to a follow-up branch. The
  minimal v0 surface (tap, type, key, launch, force_stop, screenshot,
  foreground, display, health) is enough to drive any E2E test that
  only needs single-point input.
- **GPS spoofing, sensor injection, kernel hiding.** Phase 2; not
  started in v0.
- **Multi-device orchestration.** Out of scope for v0. The Python
  client is thread-safe; running two `QaLabDevice` instances against
  two different ports works trivially.
- **The LLM agent loop.** Out of scope for v0. The agent
  developer guide ([`agent-developer-guide.md`](./agent-developer-guide))
  shows the recommended shape.
