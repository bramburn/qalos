---
id: api
title: API reference
sidebar_label: API
sidebar_position: 5
description: Every v0 endpoint, with request/response shape, error codes, and a curl example.
---

# API reference

The on-device service speaks HTTP/JSON on `127.0.0.1:9000` (default).
All responses are JSON. All errors return HTTP 4xx/5xx with the same
body shape.

## Conventions

### Request

- Path is case-sensitive.
- `GET` parameters go in the query string.
- `POST` parameters go in a JSON object body with `Content-Type: application/json`.
- The maximum body size is 64 KiB.

### Response (success)

```json
{ "status": "ok", ... }
```

### Response (error)

```json
{ "status": "error", "message": "<human-readable reason>" }
```

| HTTP status | Meaning |
| --- | --- |
| 200 | success |
| 400 | bad request (malformed JSON, missing field, out-of-range value) |
| 403 | non-loopback client (defence-in-depth; the server is bound to 127.0.0.1) |
| 404 | no such endpoint |
| 413 | body larger than 64 KiB |
| 500 | internal binder error |
| 501 | not implemented (used for endpoints deferred to a future version) |
| 503 | a framework dependency (InputManager / ActivityManager / DisplayManager) is not available yet |

## Endpoints

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | [`/health`](#get-health) | liveness check |
| `GET` | [`/capabilities`](#get-capabilities) | service version, API version, supported endpoints, build id |
| `GET` | [`/info`](#get-info) | device metadata (model, Android version, display size, foreground package) |
| `GET` | [`/display`](#get-display) | screen dimensions |
| `GET` | [`/screenshot`](#get-screenshot) | PNG, base64-encoded |
| `GET` | [`/foreground`](#get-foreground) | top focused package |
| `POST` | [`/tap`](#post-tap) | tap at `(x, y)` |
| `POST` | [`/type`](#post-type) | type a string |
| `POST` | [`/key`](#post-key) | press / release a hardware key |
| `POST` | [`/launch`](#post-launch) | launch an app |
| `POST` | [`/force_stop`](#post-force_stop) | force-stop an app |
| `POST` | [`/long_press`](#post-long_press) | press and hold at `(x, y)` |
| `POST` | [`/swipe`](#post-swipe) | linear drag from `(x1, y1)` to `(x2, y2)` |
| `POST` | [`/pinch`](#post-pinch) | two-finger zoom centered at `(cx, cy)` |

### `GET /health`

A minimal liveness probe. Use this to check the service is up.
For richer metadata (build id, uptime, supported endpoints) call
[`/capabilities`](#get-capabilities). For device hardware info
(manufacturer, model, display) call [`/info`](#get-info).

```bash
curl http://localhost:9000/health
```

```json
{
  "status": "ok",
  "service": "qalos-remote-control",
  "android": "15"
}
```

### `GET /capabilities`

Service metadata + the full list of supported endpoints. The endpoint
list is the source of truth for what the client can call. If you
target a new endpoint that does not appear here, the server will
return 404.

```bash
curl http://localhost:9000/capabilities
```

```json
{
  "service": "qalos-remote-control",
  "service_version": "0.1.0",
  "api_version": 1,
  "build_id": "2026-09-05-abc123",
  "started_at": 1735689600000,
  "uptime_ms": 12345,
  "endpoints": [
    "health", "capabilities", "info", "display", "screenshot",
    "foreground", "tap", "type", "key", "launch", "force_stop",
    "long_press", "swipe", "pinch"
  ]
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `service_version` | string | semantic version of the qalos build |
| `api_version` | int | wire-shape version; bump on backward-incompatible changes |
| `build_id` | string | `ro.qalos.build_id` from the product overlay (set at `lunch` time) |
| `started_at` | int (epoch ms) | when this service instance started |
| `uptime_ms` | int | ms since `started_at` |
| `endpoints` | string[] | every route the server accepts; clients should use this for capability checks |

### `GET /info`

Device-side metadata. Answers the question "what am I talking to?".

```bash
curl http://localhost:9000/info
```

```json
{
  "manufacturer": "Google",
  "model": "Pixel 7",
  "android_release": "15",
  "android_sdk": 35,
  "display_width": 1080,
  "display_height": 2400,
  "foreground_package": "com.android.launcher"
}
```

| Field | Type | Meaning |
| --- | --- | --- |
| `manufacturer` | string | `Build.MANUFACTURER` |
| `model` | string | `Build.MODEL` |
| `android_release` | string | `Build.VERSION.RELEASE` |
| `android_sdk` | int | `Build.VERSION.SDK_INT` |
| `display_width` | int | primary display width in pixels |
| `display_height` | int | primary display height in pixels |
| `foreground_package` | string | top focused task's package (or `""` if home) |

### `GET /display`

```bash
curl http://localhost:9000/display
```

```json
{ "width": 1080, "height": 2400 }
```

### `GET /screenshot`

```bash
curl 'http://localhost:9000/screenshot?width=480&height=800&quality=85'
```

| Param | Default | Range | Meaning |
| --- | --- | --- | --- |
| `width` | 0 (native) | `0..display_width` | **capture** width (not downscale) |
| `height` | 0 (native) | `0..display_height` | **capture** height (not downscale) |
| `display` | 0 | integer | display ID (0 = primary) |
| `quality` | 85 | `1..100` | PNG compression hint (see note) |

```json
{
  "image": "<base64 PNG bytes>",
  "width": 1080,
  "height": 2400,
  "format": "png"
}
```

`width` and `height` of `0` mean "capture at the display's native
resolution." A non-zero value asks the framework to capture at that
resolution; the framework does not down-scale, so a captured image
of `480x800` is exactly `480x800` pixels (not a 1080x2400 source
down-scaled). The `width` and `height` in the response are the
**effective** capture dimensions — when `?width=0&height=0` is
sent, the client sees the native display resolution, not 0.
(Updated v0.1.1 review-triage 2026-09-05.)

**`quality` is a forward-compatibility hint, not a tuning knob.**
Android's `Bitmap.compress(CompressFormat.PNG, quality, ...)` ignores
the `quality` argument for PNG (PNG is lossless; the parameter is
reserved for JPEG/WEBP backends). The on-device service accepts and
echoes the field so the API surface matches a future JPEG backend,
but the encoded bytes today are independent of `quality` — sending
`quality=1` and `quality=100` produces identical output. Clients
that care about payload size should request a smaller `width`/`height`
instead. Review-triage 2026-09-05.

The capture is performed by `android.window.ScreenCapture.captureDisplay`
on a worker thread (the binder thread is not blocked). The underlying
`HardwareBuffer` is released after the PNG is encoded.

### `GET /foreground`

```bash
curl http://localhost:9000/foreground
```

```json
{ "package": "com.example.app" }
```

Empty string if the home screen is focused.

### `POST /tap`

```bash
curl -X POST http://localhost:9000/tap \
  -H 'Content-Type: application/json' \
  -d '{"x": 540, "y": 1200, "display": 0}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `x` | int | yes | pixel x (0..width-1) |
| `y` | int | yes | pixel y (0..height-1) |
| `display` | int | no (default 0) | display ID |

Returns `{"status":"ok"}` on success; HTTP 400 if the coordinates
are negative or outside the display.

### `POST /type`

```bash
curl -X POST http://localhost:9000/type \
  -H 'Content-Type: application/json' \
  -d '{"text": "hello world"}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `text` | string | yes | the string to type (max 1024 chars) |

Returns `{"status":"ok"}` on success; HTTP 400 if the text contains
characters that cannot be expressed as `KeyEvent`s (most CJK and
emoji) — the on-device service surfaces this rather than silently
dropping the call.

### `POST /key`

```bash
curl -X POST http://localhost:9000/key \
  -H 'Content-Type: application/json' \
  -d '{"key_code": 4, "down": true}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `key_code` | int | yes | Android `KeyEvent.KEYCODE_*` constant (e.g. 4 = BACK) |
| `down` | bool | no (default true) | true for press, false for release. The JSON wire format is lowercase `true` / `false`; the AIDL signature uses Java `boolean`. |

Returns `{"status":"ok"}` on success.

### `POST /launch`

```bash
curl -X POST http://localhost:9000/launch \
  -H 'Content-Type: application/json' \
  -d '{"package": "com.example.app"}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `package` | string | yes | the package name to launch |

Returns `{"status":"ok"}` on success; HTTP 500 if the package is not
installed or the activity fails to start.

### `POST /force_stop`

```bash
curl -X POST http://localhost:9000/force_stop \
  -H 'Content-Type: application/json' \
  -d '{"package": "com.example.app"}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `package` | string | yes | the package name to stop |

Returns `{"status":"ok"}` on success.

### `POST /long_press`

Press and hold at `(x, y)` for `duration_ms` milliseconds. Useful for
opening context menus. Runs on a worker thread.

```bash
curl -X POST http://localhost:9000/long_press \
  -H 'Content-Type: application/json' \
  -d '{"x": 540, "y": 1200, "duration_ms": 500, "display": 0}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `x` | int | yes | pixel x (0..width-1) |
| `y` | int | yes | pixel y (0..height-1) |
| `duration_ms` | int | yes | hold duration in ms; clamped to `[1, 5000]` on-device |
| `display` | int | no (default 0) | display ID |

Returns `{"status":"ok"}` immediately. The actual press-and-release
completes in the background. The HTTP 200 confirms only that the
input was queued.

### `POST /swipe`

Linear drag from `(x1, y1)` to `(x2, y2)` with `steps` intermediate
`ACTION_MOVE` events. More steps = smoother animation. Runs on a
worker thread.

```bash
curl -X POST http://localhost:9000/swipe \
  -H 'Content-Type: application/json' \
  -d '{"x1": 100, "y1": 500, "x2": 900, "y2": 500, "steps": 20, "duration_ms": 300, "display": 0}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `x1`, `y1` | int | yes | start coordinates (0..width-1, 0..height-1) |
| `x2`, `y2` | int | yes | end coordinates |
| `steps` | int | yes | intermediate MOVE events; clamped to `[1, 200]` on-device |
| `duration_ms` | int | yes | total swipe duration; clamped to `[1, 10000]` on-device |
| `display` | int | no (default 0) | display ID |

### `POST /pinch`

Two-finger zoom centered at `(cx, cy)`. The two pointers start at
`(cx - r1, cy)` and `(cx + r1, cy)`, and the radius interpolates to
`r2` over `duration_ms`. `r2 > r1` is a zoom-in; `r2 < r1` is a
zoom-out. Runs on a worker thread.

```bash
curl -X POST http://localhost:9000/pinch \
  -H 'Content-Type: application/json' \
  -d '{"cx": 540, "cy": 1200, "r1": 100, "r2": 300, "steps": 20, "duration_ms": 300, "display": 0}'
```

| Field | Type | Required | Meaning |
| --- | --- | --- | --- |
| `cx`, `cy` | int | yes | center of the pinch, must be inside the display |
| `r1` | int | yes | starting radius in pixels (per pointer); must be `>= 1` |
| `r2` | int | yes | ending radius in pixels; must be `>= 1` |
| `steps` | int | yes | intermediate MOVE events; clamped to `[1, 200]` on-device |
| `duration_ms` | int | yes | total pinch duration; clamped to `[1, 10000]` on-device |
| `display` | int | no (default 0) | display ID |

## Python client

The full Python client lives at
[`tools/qa-lab-os/client.py`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/tools/qa-lab-os/client.py).
The 92-test suite at
[`tools/qa-lab-os/tests/`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/tools/qa-lab-os/tests/)
exercises every endpoint against the mock server.

## `qalos` CLI

The `qalos` command (installed by `pip install -e .`) is a thin
wrapper around the Python client. Run `qalos --help` to list the
subcommands. Most useful ones:

```bash
qalos status                 # /capabilities + /info
qalos devices                # discover reachable services via adb
qalos tap 540 1200           # one-shot tap
qalos long-press 540 1200 500
qalos swipe 100 500 900 500
qalos pinch 540 1200 100 300
qalos screenshot out.png
qalos forward                # adb forward tcp:9000 tcp:9000
qalos wait-until-alive
```

See [`connecting.md`](./connecting) for the full connection guide.

## Curl cookbook

```bash
# Health
curl -s http://localhost:9000/health | jq

# Display
curl -s http://localhost:9000/display | jq

# Capabilities
curl -s http://localhost:9000/capabilities | jq

# Tap centre
curl -s -X POST http://localhost:9000/tap \
  -H 'Content-Type: application/json' \
  -d '{"x": 540, "y": 1200}' | jq

# Screenshot to file
curl -s 'http://localhost:9000/screenshot?width=540&height=1200' \
  | jq -r .image | base64 -d > screen.png

# Type text
curl -s -X POST http://localhost:9000/type \
  -H 'Content-Type: application/json' \
  -d '{"text": "hello"}' | jq

# Foreground
curl -s http://localhost:9000/foreground | jq
```
