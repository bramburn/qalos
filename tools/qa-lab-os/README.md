# qa-lab-os (Python tools)

Python client SDK, mock server, and CLI for the on-device
RemoteControlService. See the
[Docusaurus site](https://bramburn.github.io/qalos/docs/qa-lab-os/)
for the architecture and API reference; this README covers only
running the tools.

## Install

```bash
# From this directory:
pip install -e ".[test]"
```

Requires Python 3.10+.

## Use the client

```python
from qa_lab_os import QaLabDevice

with QaLabDevice("localhost", 9000) as device:
    print(device.health())
    print(device.display_size)
    device.tap(540, 1200)
    device.type_text("hello")
    device.screenshot().save("screen.png")
    print(device.foreground_package)
    # v0.1: gestures + discovery
    device.long_press(540, 1200, 500)
    device.swipe(100, 500, 900, 500)
    device.pinch(540, 1200, 100, 300)
    print(device.capabilities)
    print(device.info)
```

The default port is 9000. When connecting to an emulator or physical
device, tunnel the port first:

```bash
adb forward tcp:9000 tcp:9000
```

## Use the CLI

The `qalos` command is installed by `pip install -e .`. It is a thin
wrapper around the Python client, intended for humans and shell
scripts that want to drive a device without writing Python.

```bash
qalos status                 # /capabilities + /info for the target device
qalos devices                # discover reachable qalos services via adb
qalos tap 540 1200           # one-shot tap
qalos long-press 540 1200 500
qalos swipe 100 500 900 500
qalos pinch 540 1200 100 300
qalos type "hello world"
qalos key 4                  # BACK; press+release by default
qalos launch com.example.app
qalos force-stop com.example.app
qalos screenshot out.png     # save to file
qalos forward                # adb forward tcp:9000 tcp:9000
qalos wait-until-alive       # block until /health returns 200
```

Most commands accept `--host` (default `localhost`), `--port`
(default 9000), and `--timeout` (default 10s). Run `qalos <cmd> --help`
for the full list of options.

The CLI is **not** a replacement for the Python SDK. The SDK is the
right tool for an LLM agent loop that needs to call the API many
times per second. The CLI is the right tool for humans running
smoke tests and shell scripts running CI checks.

## Run the mock server

For host-side development without an AVD:

```bash
python -m qa_lab_os.mock_server --port 9000
# or, after `pip install -e .`:
qa-lab-os-mock --port 9000
```

The mock listens on `127.0.0.1` by default and returns canned
responses. It records every call so you can assert on the call shape
in your own tests:

```python
from qa_lab_os.mock_server import MockRemoteControlServer
from qa_lab_os import QaLabDevice

with MockRemoteControlServer() as server:
    device = QaLabDevice("localhost", server.port)
    device.tap(10, 20)
    assert server.api.calls == [
        ("POST", "/tap", {"x": 10, "y": 20, "display": 0}),
    ]
```

## Run the tests

```bash
pytest
```

The tests spin up the mock server on a random free port and exercise
the client end-to-end. They run on any host with Python 3.10+ — no
AOSP build required. 92 tests cover all 14 endpoints, the client
SDK, the mock server, and the CLI.

## License

MIT, matching the rest of qalos. See `LICENSE` in the repo root.

## File layout

```
tools/qa-lab-os/
├── README.md          ← you are here
├── pyproject.toml
├── client.py          ← QaLabDevice class + dataclasses (DisplaySize, ServiceInfo, DeviceInfo)
├── mock_server.py     ← MockRemoteControlServer + MockRemoteControlAPI
├── cli.py             ← `qalos` command-line tool
└── tests/
    ├── conftest.py
    ├── test_client.py
    ├── test_mock_server.py
    └── test_cli.py
```
