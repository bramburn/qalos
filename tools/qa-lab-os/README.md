# qa-lab-os (Python tools)

Python client SDK and mock server for the on-device
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
```

The default port is 9000. When connecting to an emulator or physical
device, tunnel the port first:

```bash
adb forward tcp:9000 tcp:9000
```

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
from qa_lab_os.client import QaLabDevice

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
AOSP build required.

## License

MIT, matching the rest of qalos. See `LICENSE` in the repo root.

## File layout

```
tools/qa-lab-os/
├── README.md          ← you are here
├── pyproject.toml
├── client.py          ← QaLabDevice class
├── mock_server.py     ← MockRemoteControlServer + MockRemoteControlAPI
└── tests/
    ├── conftest.py
    ├── test_client.py
    └── test_mock_server.py
```
