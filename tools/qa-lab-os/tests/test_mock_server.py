# SPDX-License-Identifier: MIT
"""Unit tests for the mock server's per-endpoint logic."""

from __future__ import annotations

import pytest

from mock_server import (
    MockRemoteControlAPI,
    MockRemoteControlServer,
    PLACEHOLDER_PNG_B64,
)


@pytest.fixture
def api() -> MockRemoteControlAPI:
    return MockRemoteControlAPI()


def _capture(api: MockRemoteControlAPI, method: str, path: str, body: dict = None):
    """Run an endpoint through the API and return (status, payload, calls)."""
    import json
    responses = []
    body_bytes = json.dumps(body or {}).encode("utf-8")
    api.handle(method, path, body_bytes, lambda s, p: responses.append((s, p)))
    return responses, api.calls


# ----------------------------------------------------------------------
# Health + display
# ----------------------------------------------------------------------

def test_health(api):
    responses, _ = _capture(api, "GET", "/health")
    assert responses == [(200, {"status": "ok", "device": "mock", "android": "mock"})]


def test_display(api):
    responses, _ = _capture(api, "GET", "/display")
    assert responses == [(200, {"width": 1080, "height": 2400})]


# ----------------------------------------------------------------------
# Foreground
# ----------------------------------------------------------------------

def test_foreground_default(api):
    responses, _ = _capture(api, "GET", "/foreground")
    assert responses == [(200, {"package": "com.android.launcher"})]


def test_foreground_custom(api):
    api.foreground_package = "com.example.app"
    responses, _ = _capture(api, "GET", "/foreground")
    assert responses == [(200, {"package": "com.example.app"})]


# ----------------------------------------------------------------------
# Tap
# ----------------------------------------------------------------------

def test_tap_happy(api):
    responses, calls = _capture(api, "POST", "/tap", {"x": 100, "y": 200})
    assert responses == [(200, {"status": "ok"})]
    assert calls == [("POST", "/tap", {"x": 100, "y": 200})]


def test_tap_rejects_missing_x(api):
    responses, _ = _capture(api, "POST", "/tap", {"y": 200})
    assert responses[0][0] == 400
    assert "x" in responses[0][1]["message"]


def test_tap_rejects_missing_y(api):
    responses, _ = _capture(api, "POST", "/tap", {"x": 100})
    assert responses[0][0] == 400
    assert "y" in responses[0][1]["message"]


def test_tap_rejects_out_of_bounds(api):
    responses, _ = _capture(api, "POST", "/tap", {"x": 99999, "y": 0})
    assert responses[0][0] == 400
    assert "outside display" in responses[0][1]["message"]


def test_tap_rejects_negative(api):
    responses, _ = _capture(api, "POST", "/tap", {"x": -1, "y": 0})
    assert responses[0][0] == 400
    assert "non-negative" in responses[0][1]["message"]


# ----------------------------------------------------------------------
# Type
# ----------------------------------------------------------------------

def test_type_happy(api):
    responses, _ = _capture(api, "POST", "/type", {"text": "hello"})
    assert responses == [(200, {"status": "ok"})]


def test_type_rejects_non_string(api):
    responses, _ = _capture(api, "POST", "/type", {"text": 123})
    assert responses[0][0] == 400
    assert "string" in responses[0][1]["message"]


def test_type_rejects_too_long(api):
    responses, _ = _capture(api, "POST", "/type", {"text": "a" * 1025})
    assert responses[0][0] == 400
    assert "1024" in responses[0][1]["message"]


# ----------------------------------------------------------------------
# Key
# ----------------------------------------------------------------------

def test_key_happy(api):
    responses, _ = _capture(api, "POST", "/key", {"key_code": 4, "down": True})
    assert responses == [(200, {"status": "ok"})]


def test_key_rejects_non_int(api):
    responses, _ = _capture(api, "POST", "/key", {"key_code": "BACK"})
    assert responses[0][0] == 400


# ----------------------------------------------------------------------
# Launch / force_stop
# ----------------------------------------------------------------------

@pytest.mark.parametrize("endpoint", ["/launch", "/force_stop"])
def test_launch_force_stop_happy(api, endpoint):
    responses, _ = _capture(api, "POST", endpoint, {"package": "com.example.app"})
    assert responses == [(200, {"status": "ok"})]


@pytest.mark.parametrize("endpoint", ["/launch", "/force_stop"])
def test_launch_force_stop_rejects_empty(api, endpoint):
    responses, _ = _capture(api, "POST", endpoint, {"package": ""})
    assert responses[0][0] == 400


# ----------------------------------------------------------------------
# Screenshot
# ----------------------------------------------------------------------

def test_screenshot_returns_placeholder_png(api):
    responses, _ = _capture(api, "GET", "/screenshot")
    assert responses[0][0] == 200
    payload = responses[0][1]
    assert payload["image"] == PLACEHOLDER_PNG_B64
    assert payload["format"] == "png"


def test_screenshot_rejects_quality_too_low(api):
    responses, _ = _capture(api, "GET", "/screenshot", {"quality": 0})
    assert responses[0][0] == 400


def test_screenshot_rejects_quality_too_high(api):
    responses, _ = _capture(api, "GET", "/screenshot", {"quality": 101})
    assert responses[0][0] == 400


# ----------------------------------------------------------------------
# Unknown endpoints
# ----------------------------------------------------------------------

def test_unknown_method_404(api):
    responses, _ = _capture(api, "DELETE", "/tap")
    assert responses[0][0] == 404


def test_unknown_path_404(api):
    responses, _ = _capture(api, "GET", "/whatever")
    assert responses[0][0] == 404
    assert "no such endpoint" in responses[0][1]["message"]


# ----------------------------------------------------------------------
# 413 body-too-large (F-5.1 regression)
# ----------------------------------------------------------------------

def test_oversized_post_body_returns_413():
    """A POST body larger than MAX_BODY_BYTES must be rejected with 413
    before any handler runs, matching the on-device service contract."""
    import requests
    from mock_server import MAX_BODY_BYTES, MockRemoteControlServer

    with MockRemoteControlServer() as srv:
        # Send a body one byte over the cap.
        oversized = b"x" * (MAX_BODY_BYTES + 1)
        resp = requests.post(
            f"http://127.0.0.1:{srv.port}/tap",
            data=oversized,
            headers={"Content-Type": "application/json"},
            timeout=5,
        )
    assert resp.status_code == 413
    payload = resp.json()
    assert payload["status"] == "error"
    assert "too large" in payload["message"].lower()


def test_boundary_body_at_max_is_accepted():
    """A POST body of exactly MAX_BODY_BYTES should NOT be rejected as
    too large (the cap is inclusive).
    """
    import json
    import requests
    from mock_server import MAX_BODY_BYTES, MockRemoteControlServer

    with MockRemoteControlServer() as srv:
        # Build a body of exactly the cap size, shaped as valid JSON
        # so the handler is reached and returns 200.
        prefix = b'{"x":1,"y":2,"display":0,"filler":"'
        suffix = b'"}'
        target = MAX_BODY_BYTES - len(prefix) - len(suffix)
        body = prefix + (b"a" * target) + suffix
        assert len(body) == MAX_BODY_BYTES
        resp = requests.post(
            f"http://127.0.0.1:{srv.port}/tap",
            data=body,
            headers={"Content-Type": "application/json"},
            timeout=5,
        )
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


# ----------------------------------------------------------------------
# Server lifecycle
# ----------------------------------------------------------------------

def test_server_uses_random_port_by_default():
    with MockRemoteControlServer() as server:
        assert server.port > 0
        # The default display is 1080x2400 from the API default.
        assert server.api.display_width == 1080


def test_server_picks_distinct_ports_on_repeated_starts():
    """Smoke test that we don't accidentally bind the same port twice."""
    with MockRemoteControlServer() as a:
        with MockRemoteControlServer() as b:
            assert a.port != b.port
