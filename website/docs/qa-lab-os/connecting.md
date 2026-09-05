---
id: connecting
title: Connecting to a device
sidebar_label: Connecting
sidebar_position: 6
description: How to find a device, set up the tunnel, and verify the service is up.
---

# Connecting to a device

The qalos RemoteControlService speaks plain HTTP/JSON on
`127.0.0.1:9000` of the device. This page covers the three ways to
reach that port from your workstation, the `qalos` discovery CLI,
and the troubleshooting steps for the most common failures.

## TL;DR

```bash
# Emulator
adb -s emulator-5554 forward tcp:9000 tcp:9000
qalos status                                # talks to localhost:9000

# Physical device over USB
adb forward tcp:9000 tcp:9000
qalos status

# Physical device over Wi-Fi (after `adb tcpip 5555`)
adb connect <device-ip>:5555
adb forward tcp:9000 tcp:9000
qalos status
```

If `qalos status` prints "is alive" and a capabilities table, you
are connected. The full output of `qalos status`:

```
qalos at localhost:9000
service              : qalos-remote-control
service_version      : 0.1.0
api_version          : 1
build_id             : 2026-09-05-abc123
uptime_ms            : 12345
started_at           : 1735689600000
device               : Google Pixel 7
android_release      : 15
android_sdk          : 35
display              : 1080x2400
foreground_package   : com.android.launcher

Endpoints:
  health
  capabilities
  info
  display
  screenshot
  foreground
  tap
  type
  key
  launch
  force_stop
  long_press
  swipe
  pinch
```

If you see "qalos at localhost:9000 is not responding", walk through
the troubleshooting section at the bottom of this page.

## How the tunnel works

The on-device service binds to `127.0.0.1:9000` inside system_server
(see D-004 in the decisions log). The service is not exposed on the
network. To reach it from the host:

- **Emulator:** `adb forward tcp:9000 tcp:9000` opens a tunnel
  from the host's `127.0.0.1:9000` to the emulator's `127.0.0.1:9000`.
- **Physical device over USB:** same `adb forward` command. The
  adb daemon forwards over the USB transport.
- **Physical device over Wi-Fi:** enable `adb tcpip 5555` once
  (with the device connected by USB), then `adb connect <ip>:5555`.
  The `adb forward` command then works the same as for USB.

In all three cases, the host can now talk to `localhost:9000` and
reach the on-device service.

## `qalos devices` — discovery

If you do not know which device has qalos running, the `qalos devices`
command finds them:

```bash
$ qalos devices
serial       | state  | port | device           | android | qalos
-------------+--------+------+------------------+---------+------------------
emulator-5554 | device | 9000 | Pixel 7          | 15      | yes (build 2026-09-05-abc123)
emulator-5556 | device | -    | Pixel 6          | ?       | no (qalos not running)
```

What it does:

1. Runs `adb devices -l` to enumerate all connected devices.
2. For each device, probes `localhost:9000..9010` with a 1s
   timeout against `/capabilities`.
3. For each reachable qalos service, reports the port, the
   manufacturer+model from `/info`, the Android version, and the
   build_id.

The default port range is `9000..9010`. Override with
`--port-range LO HI`.

## `qalos status` — single-device health

Once you know the host:port (almost always `localhost:9000` after
`adb forward`), `qalos status` confirms the service is up and tells
you what it can do:

```bash
qalos status                    # localhost:9000
qalos status --port 9001        # different forward port
qalos status --host 10.0.0.42 --port 9000   # network-attached service
```

Exits 0 on 200, 1 otherwise. Useful in CI smoke tests:

```bash
qalos status || (echo "qalos not running" && exit 1)
```

## `qalos forward` — set up the tunnel

The `qalos forward` command wraps `adb forward tcp:N tcp:9000` so
you do not have to type it every time:

```bash
qalos forward                    # default: tcp:9000 -> tcp:9000
qalos forward --port 9001        # forward tcp:9001 instead
qalos forward --serial emulator-5554    # multi-device
```

After `qalos forward`, `qalos status` should succeed. If it
returns "adb forward failed", the port is already in use on the
host, or the wrong serial was specified.

## Multi-device orchestration

Each device needs its own host port. The standard pattern is one
port per device, all mapping to the on-device `9000`:

```bash
adb -s emulator-5554 forward tcp:9000 tcp:9000
adb -s emulator-5556 forward tcp:9001 tcp:9000

qalos --port 9000 tap 540 1200        # device 1
qalos --port 9001 tap 540 1200        # device 2
```

In Python, use two `QaLabDevice` instances:

```python
from client import QaLabDevice

with QaLabDevice("localhost", 9000) as a, \
     QaLabDevice("localhost", 9001) as b:
    a.launch("com.delivery.driver")
    b.launch("com.delivery.customer")
    # both run in parallel; the client is thread-safe
```

## Troubleshooting

### `qalos status` says "not responding"

The on-device service is not running, or the tunnel is not in place.
Check in order:

```bash
# 1. Is adb forwarding set up?
adb forward --list                     # should show tcp:9000 -> tcp:9000
# if not:
adb forward tcp:9000 tcp:9000

# 2. Is the device connected and authorised?
adb devices                            # "device" state, not "unauthorized"

# 3. Is the qalos service running on the device?
adb shell logcat -d -s QaRemoteCtl | tail -50
# expect a line like:
#   I/QaRemoteCtl: remote control service ready on port 9000 (version 0.1.0)
# if you see nothing, the qalos image is not installed, or
# system_server crashed.

# 4. Does /health return 200?
adb shell curl -s http://127.0.0.1:9000/health   # may not have curl
# fallback: use qalos with verbose output
qalos status --timeout 5
```

### `qalos forward` fails with "port already in use"

Another process is holding the host port. Either pick a different
port:

```bash
qalos forward --port 9100
qalos status --port 9100
```

or find and kill the other process:

```powershell
# Windows: find what's on port 9000
Get-NetTCPConnection -LocalPort 9000
```

### `qalos status` says "device" field missing

You are talking to a v0 (pre-v0.1) build. The `device` field was
removed from `/health` in v0.1 and moved to `/info`. Call
`qalos info` to see the device metadata.

### `qalos devices` shows "qalos not running"

The adb device is connected but the qalos image is not booted, or
the RemoteControlService failed to start. The on-host logcat is
the source of truth:

```bash
adb shell logcat -d -s QaRemoteCtl,SysService,SystemServer | tail -100
```

The most common failure is a missing AOSP patch (one of the three
framework-overlay patches in `packages/apps/RemoteControlService/patches/`).
If the patch check fails, the service will not be in `SystemServer`'s
service list at all.

### `qalos screenshot` times out

The PNG capture is slow on the first call (SurfaceFlinger
warm-up). Default timeout is 30s. If you need faster captures,
down-scale the request:

```bash
qalos screenshot out.png --width 540 --height 1200
```

The on-device worker thread has a 30s hard cap to prevent
unbounded hangs. A timeout returns HTTP 500 with the message
"screenshot timed out after 30s".

### `qalos long-press` / `swipe` / `pinch` does not appear to do anything

These run on a worker thread; the HTTP 200 response confirms only
that the input was queued, not that it executed. To verify:

```bash
adb shell logcat -d -s QaRemoteCtl | tail -30
```

If the worker logged an exception, you'll see the stack trace. The
most common cause is `InputManagerService` not yet bound (the
service is started but `onBootPhase(PHASE_BOOT_COMPLETED)` has not
yet run). The endpoint will return HTTP 503 in that case.

## See also

- [API reference](./api) — every endpoint, every error code
- [Build guide](./build-guide) — how to build, flash, verify
- [Architecture](./architecture) — what runs where
