# SPDX-License-Identifier: MIT
"""Mock implementation of the qalos RemoteControlService HTTP/JSON API.

A pure-Python stand-in for the on-device service, intended for
host-side testing of the Python client SDK and any future LLM agent
loop. It is **not** a behaviour-faithful emulator — the real service
calls into ``InputManagerService``, ``IActivityManager`` and
``SurfaceControl``; this mock just records what was asked and
returns canned responses.

Run standalone::

    python -m qa_lab_os.mock_server --port 9000

Use from a test::

    from qa_lab_os.mock_server import MockRemoteControlServer
    with MockRemoteControlServer() as server:
        device = QaLabDevice("localhost", server.port)
        device.tap(10, 20)
        assert server.calls == [("POST", "/tap", {"x": 10, "y": 20, "display": 0})]
"""

from __future__ import annotations

import argparse
import base64
import json
import logging
import socket
import threading
from contextlib import contextmanager
from http.server import BaseHTTPRequestHandler, ThreadingHTTPServer
from typing import Iterator, List, Tuple

LOGGER = logging.getLogger(__name__)

DEFAULT_DISPLAY_WIDTH = 1080
DEFAULT_DISPLAY_HEIGHT = 2400


def _strip_query(path: str) -> str:
    """Return the path portion of a request-target, dropping `?...`."""
    q = path.find("?")
    return path if q < 0 else path[:q]


def _parse_query(path: str) -> dict:
    """Parse a `key=value&...` query string into a dict.

    Each value is an int if it parses cleanly, else the raw string.
    Always returns a dict; empty query returns an empty dict.
    """
    q = path.find("?")
    if q < 0 or q == len(path) - 1:
        return {}
    raw = path[q + 1:]
    out: dict = {}
    for pair in raw.split("&"):
        if not pair:
            continue
        eq = pair.find("=")
        if eq < 0:
            key, value = pair, ""
        else:
            key, value = pair[:eq], pair[eq + 1:]
        # Try integer parse — matches the on-device server's
        # `body.optInt` behaviour for the screenshot parameters.
        try:
            out[key] = int(value)
        except (TypeError, ValueError):
            out[key] = value
    return out

# 1x1 transparent PNG, base64-encoded. Returned for every screenshot.
PLACEHOLDER_PNG_B64 = base64.b64encode(
    bytes.fromhex(
        "89504e470d0a1a0a0000000d49484452000000010000000108060000001f15c4"
        "890000000d49444154789c6300010000000500010d0a2db40000000049454e44ae426082"
    )
).decode("ascii")


class _Handler(BaseHTTPRequestHandler):
    """Per-request handler that delegates to the server instance."""

    server_version = "qalos-mock/0.1"

    # Injected by `MockRemoteControlServer` after construction.
    api: "MockRemoteControlAPI"

    def log_message(self, format: str, *args) -> None:  # noqa: A002 (override)
        LOGGER.debug(format, *args)

    # Disable default stderr access logging; we already redirect.

    def do_GET(self) -> None:  # noqa: N802 (BaseHTTPRequestHandler API)
        path = _strip_query(self.path)
        self.api.handle(self.command, path, b"", self._respond,
                        query=_parse_query(self.path))

    def do_POST(self) -> None:  # noqa: N802
        length = int(self.headers.get("Content-Length", "0"))
        body = self.rfile.read(length) if length > 0 else b""
        path = _strip_query(self.path)
        self.api.handle(self.command, path, body, self._respond,
                        query=_parse_query(self.path))

    def _respond(self, status: int, payload: dict) -> None:
        body = json.dumps(payload).encode("utf-8")
        self.send_response(status)
        self.send_header("Content-Type", "application/json; charset=utf-8")
        self.send_header("Content-Length", str(len(body)))
        self.send_header("Connection", "close")
        self.end_headers()
        self.wfile.write(body)


class MockRemoteControlAPI:
    """State + behaviour of the mock service.

    Holds the canned response values and a record of the calls that
    were made. Thread-safe for our usage — each request runs on its
    own thread (the server is ``ThreadingHTTPServer``).
    """

    def __init__(
        self,
        *,
        display_width: int = DEFAULT_DISPLAY_WIDTH,
        display_height: int = DEFAULT_DISPLAY_HEIGHT,
        foreground_package: str = "com.android.launcher",
    ) -> None:
        self.display_width = display_width
        self.display_height = display_height
        self.foreground_package = foreground_package
        self._lock = threading.Lock()
        self._calls: List[Tuple[str, str, dict]] = []

    @property
    def calls(self) -> List[Tuple[str, str, dict]]:
        """Return a copy of the recorded calls."""
        with self._lock:
            return list(self._calls)

    def clear_calls(self) -> None:
        with self._lock:
            self._calls.clear()

    def handle(
        self,
        method: str,
        path: str,
        body: bytes,
        respond,
        query: dict | None = None,
    ) -> None:
        try:
            decoded = json.loads(body) if body else {}
        except json.JSONDecodeError as exc:
            respond(400, {"status": "error", "message": f"invalid JSON: {exc}"})
            return

        if not isinstance(decoded, dict):
            respond(400, {"status": "error", "message": "body must be a JSON object"})
            return

        # Merge query params over the body. Body wins on conflict, so
        # POST-style endpoints (which carry JSON) take precedence over
        # the (usually empty) query string. GET-style endpoints
        # (which carry no body) get their params from the query.
        if query:
            merged = {**query, **decoded}
        else:
            merged = decoded

        with self._lock:
            self._calls.append((method, path, merged))

        try:
            self._dispatch(method, path, merged, respond)
        except _BadRequest as exc:
            respond(400, {"status": "error", "message": str(exc)})
        except _ServiceUnavailable as exc:
            respond(503, {"status": "error", "message": str(exc)})

    # ------------------------------------------------------------------
    # Dispatch
    # ------------------------------------------------------------------

    def _dispatch(self, method: str, path: str, body: dict, respond) -> None:
        if method == "GET" and path == "/health":
            respond(200, {
                "status": "ok",
                "device": "mock",
                "android": "mock",
            })
            return
        if method == "GET" and path == "/display":
            respond(200, {"width": self.display_width, "height": self.display_height})
            return
        if method == "GET" and path == "/screenshot":
            self._handle_screenshot(body, respond)
            return
        if method == "GET" and path == "/foreground":
            respond(200, {"package": self.foreground_package})
            return
        if method == "POST" and path == "/tap":
            self._handle_tap(body, respond)
            return
        if method == "POST" and path == "/type":
            self._handle_type(body, respond)
            return
        if method == "POST" and path == "/key":
            self._handle_key(body, respond)
            return
        if method == "POST" and path == "/launch":
            self._handle_launch(body, respond)
            return
        if method == "POST" and path == "/force_stop":
            self._handle_force_stop(body, respond)
            return
        respond(404, {"status": "error", "message": f"no such endpoint: {method} {path}"})

    # ------------------------------------------------------------------
    # Per-endpoint logic — mirrors the on-device validation rules so
    # the client SDK is exercised against the same error shapes.
    # ------------------------------------------------------------------

    @staticmethod
    def _need(body: dict, key: str) -> object:
        if key not in body:
            raise _BadRequest(f"missing field: {key}")
        return body[key]

    def _handle_screenshot(self, body: dict, respond) -> None:
        quality = int(body.get("quality", 85))
        if not (1 <= quality <= 100):
            raise _BadRequest(f"quality must be in [1, 100], got {quality}")
        width = int(body.get("width", 0))
        height = int(body.get("height", 0))
        if width < 0 or height < 0:
            raise _BadRequest("width and height must be non-negative")
        respond(200, {
            "image": PLACEHOLDER_PNG_B64,
            "width": width or self.display_width,
            "height": height or self.display_height,
            "format": "png",
        })

    def _handle_tap(self, body: dict, respond) -> None:
        x = int(self._need(body, "x"))
        y = int(self._need(body, "y"))
        if x < 0 or y < 0:
            raise _BadRequest("coordinates must be non-negative")
        if x >= self.display_width or y >= self.display_height:
            raise _BadRequest(
                f"coordinates ({x}, {y}) outside display "
                f"({self.display_width}x{self.display_height})"
            )
        respond(200, {"status": "ok"})

    def _handle_type(self, body: dict, respond) -> None:
        text = self._need(body, "text")
        if not isinstance(text, str):
            raise _BadRequest("text must be a string")
        if len(text) > 1024:
            raise _BadRequest("text too long (>1024 chars)")
        respond(200, {"status": "ok"})

    def _handle_key(self, body: dict, respond) -> None:
        code = self._need(body, "key_code")
        if not isinstance(code, int):
            raise _BadRequest("key_code must be an integer")
        respond(200, {"status": "ok"})

    def _handle_launch(self, body: dict, respond) -> None:
        package = self._need(body, "package")
        _validate_package_name(package)
        respond(200, {"status": "ok"})

    def _handle_force_stop(self, body: dict, respond) -> None:
        package = self._need(body, "package")
        _validate_package_name(package)
        respond(200, {"status": "ok"})


class _BadRequest(Exception):
    pass


class _ServiceUnavailable(Exception):
    pass


def _validate_package_name(package_name: object) -> None:
    """Mirror the on-device service's package-name grammar.

    Raises `_BadRequest` if the name is empty, has leading/trailing
    dots, contains `..`, or contains characters that are not valid
    Java identifier parts.
    """
    if not isinstance(package_name, str) or not package_name:
        raise _BadRequest("package must be a non-empty string")
    if (
        not package_name[0].isidentifier()
        or ".." in package_name
        or package_name.startswith(".")
        or package_name.endswith(".")
    ):
        raise _BadRequest(f"invalid packageName: {package_name}")
    for ch in package_name[1:]:
        if ch != "." and not ch.isidentifier():
            raise _BadRequest(f"invalid packageName: {package_name}")


class MockRemoteControlServer:
    """A running mock of the qalos service on a random free port.

    Use as a context manager::

        with MockRemoteControlServer() as server:
            device = QaLabDevice("localhost", server.port)
            ...
    """

    def __init__(self, host: str = "127.0.0.1", port: int = 0) -> None:
        self._api = MockRemoteControlAPI()
        # Bind the handler to the api instance.
        self._handler_cls = type(
            "_BoundHandler",
            (_Handler,),
            {"api": self._api},
        )
        self._httpd = ThreadingHTTPServer((host, port), self._handler_cls)
        self._thread: threading.Thread | None = None
        self.host = self._httpd.server_address[0]
        self.port = int(self._httpd.server_address[1])

    @property
    def api(self) -> MockRemoteControlAPI:
        return self._api

    def start(self) -> None:
        self._thread = threading.Thread(
            target=self._httpd.serve_forever,
            name="qalos-mock-http",
            daemon=True,
        )
        self._thread.start()
        LOGGER.info("mock listening on %s:%d", self.host, self.port)

    def stop(self) -> None:
        self._httpd.shutdown()
        self._httpd.server_close()
        if self._thread is not None:
            self._thread.join(timeout=2)

    def __enter__(self) -> "MockRemoteControlServer":
        self.start()
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.stop()


def _find_free_port() -> int:
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as sock:
        sock.bind(("127.0.0.1", 0))
        return sock.getsockname()[1]


def main() -> None:
    logging.basicConfig(level=logging.INFO, format="%(asctime)s %(levelname)s %(message)s")
    parser = argparse.ArgumentParser(description=__doc__.splitlines()[0])
    parser.add_argument("--host", default="127.0.0.1")
    parser.add_argument("--port", type=int, default=0,
                        help="0 picks a free port (default)")
    args = parser.parse_args()
    port = args.port or _find_free_port()
    with MockRemoteControlServer(host=args.host, port=port) as server:
        print(f"qalos mock listening on http://{server.host}:{server.port}")
        print("Press Ctrl-C to stop.")
        try:
            # Block forever; the daemon thread keeps the server alive.
            threading.Event().wait()
        except KeyboardInterrupt:
            pass


if __name__ == "__main__":
    main()
