# vendor/aqa/server — aqa_server automation daemon

Native C++17 daemon exposing an HTTP/JSON REST API so the device can be
driven from any host on the same network. Started by init from
`aqa_server.rc`, built by `Android.bp`, installed to `/system/bin/aqa_server`.

## Endpoints

| Endpoint | Method | Body | Action |
| --- | --- | --- | --- |
| `/v1/health` | GET | — | liveness probe |
| `/v1/tap` | POST | `{"x":int,"y":int}` | touch tap via `/dev/uinput` |
| `/v1/swipe` | POST | `{"x1","y1","x2","y2","duration_ms"}` | interpolated swipe (~60fps) |
| `/v1/key` | POST | `{"keycode":int}` | Android keycode press/release |
| `/v1/type` | POST | `{"text":string}` | `input text <shell-quoted>` |
| `/v1/app/start` | POST | `{"package","activity"}` | `am start -n pkg/activity` |
| `/v1/app/stop` | POST | `{"package":string}` | `am force-stop pkg` |
| `/v1/screenshot` | GET | — | PNG bytes, `Content-Type: image/png` |
| `/v1/sms/inbox` | GET | — | `{"raw": "<content query output>"}` |

400 `{"error":"..."}` on a missing/!numeric field; 404 `{"error":"not_found"}`;
500 `{"error":"screencap_failed"}`.

Display is hard-coded to 1440x3120 (Pixel 7 Pro QHD+) as `kDisplayWidth` /
`kDisplayHeight` in `src/main.cpp`.

## Architecture

```text
aqa_server  (init service, class=main, user=root, seclabel=u:r:su:s0)
├── HttpServer            0.0.0.0:8080, single-threaded accept loop
│     └── handleRequest() routes on path, then JSON-scan the body
├── UInputInjector        /dev/uinput, BUS_VIRTUAL multi-touch digitizer
└── shell-outs to         /system/bin/{input,am,content,screencap}
```

Signal handling: `SIGTERM`/`SIGINT` are blocked with `pthread_sigmask()`
**before** the accept thread is created, then consumed with `sigwait()`. That
ordering is what makes `stop aqa_server` deterministic — blocking afterwards
leaves the default disposition in place and the process is killed from an
arbitrary thread. `SIGPIPE` is ignored so a client disconnecting mid-response
cannot take the daemon down.

`/v1/screenshot` captures to a temp file under `/data/local/tmp` and reads it
back rather than piping `screencap -p` into a stream. The piped form is
fragile for binary output and makes failure indistinguishable from an empty
framebuffer.

`/dev/uinput` needs no ueventd rule: the daemon runs as root, so it can open
the node whatever its mode. (An earlier revision copied a fragment over
`$(TARGET_COPY_OUT_VENDOR)/etc/ueventd.rc` — that would have clobbered
pantah's own ueventd rules.)

## Security

This daemon is for **QA testbed images only**:

- runs as root
- `seclabel u:r:su:s0` (full privileged domain, no custom SELinux domain)
- **no authentication**, bound to `0.0.0.0`
- can launch/force-stop any package
- can read the SMS inbox

Do not ship it in a production image. Constrain access with iptables or keep
the device on an isolated network.

Because the daemon runs under the `su` domain there is deliberately **no
`vendor/aqa/sepolicy/`** — a custom `.te` would require types that do not
exist in AOSP (`am_exec`, `content_exec`, …) and would fail `checkpolicy` if
ever wired into `PRODUCT_SEPOLICY_DIRS`.

## Host smoke test

The read-only endpoints need no device hardware, so the daemon can be
compiled and partially exercised on a Linux host:

```bash
g++ -std=c++17 -O2 -pthread src/main.cpp src/uinput_injector.cpp src/http_server.cpp -o aqa_server
./aqa_server &            # /dev/uinput init fails; endpoint still serves
curl -s localhost:8080/v1/health
```

On device:

```bash
adb shell curl -s localhost:8080/v1/health     # or from any host on the LAN
curl -s http://<device-ip>:8080/v1/screenshot --output screen.png
```

## Limitations

- No TLS, no auth, no rate limiting.
- Single-threaded accept loop — fine for QA, not for high request rates.
- Blocking shell-outs serialise requests; a hung `am` stalls the loop.
- Flat JSON scanner, not a general parser: no nesting, no escaping of `\"`
  inside values.
- No paging on `/v1/sms/inbox` — it returns the raw `content query` output.