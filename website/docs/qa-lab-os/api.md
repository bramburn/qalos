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
| 404 | no such endpoint |
| 413 | body larger than 64 KiB |
| 500 | internal binder error |
| 503 | a framework dependency (InputManager / ActivityManager / DisplayManager) is not available yet |

## Endpoints (v0)

| Method | Path | Purpose |
| --- | --- | --- |
| `GET` | [`/health`](#get-health) | liveness check |
| `GET` | [`/display`](#get-display) | screen dimensions |
| `GET` | [`/screenshot`](#get-screenshot) | PNG, base64-encoded |
| `GET` | [`/foreground`](#get-foreground) | top focused package |
| `POST` | [`/tap`](#post-tap) | tap at `(x, y)` |
| `POST` | [`/type`](#post-type) | type a string |
| `POST` | [`/key`](#post-key) | press / release a hardware key |
| `POST` | [`/launch`](#post-launch) | launch an app |
| `POST` | [`/force_stop`](#post-force_stop) | force-stop an app |

Deferred to a follow-up: `/long_press`, `/swipe`, `/pinch`.

### `GET /health`

```bash
curl http://localhost:9000/health
```

```json
{
  "status": "ok",
  "device": "google/panther/panther:15/...",
  "android": "15"
}
```

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
| `quality` | 85 | `1..100` | PNG compression level |

```json
{
  "image": "<base64 PNG bytes>",
  "width": 480,
  "height": 800,
  "format": "png"
}
```

`width` and `height` of `0` mean "capture at the display's native
resolution." A non-zero value asks the framework to capture at that
resolution; the framework does not down-scale, so a captured image
of `480x800` is exactly `480x800` pixels (not a 1080x2400 source
down-scaled). The PNG is compressed at the requested quality; lower
quality → smaller payload → faster LLM inference.

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

## Python client

The full Python client lives at
[`tools/qa-lab-os/client.py`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/tools/qa-lab-os/client.py).
The 51-test suite at
[`tools/qa-lab-os/tests/`](https://github.com/bramburn/qalos/blob/feat/qa-lab-os-v0/tools/qa-lab-os/tests/)
exercises every endpoint against the mock server.

## Curl cookbook

```bash
# Health
curl -s http://localhost:9000/health | jq

# Display
curl -s http://localhost:9000/display | jq

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
