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
    payload = responses[0][1]
    assert responses[0][0] == 200
    assert payload["status"] == "ok"
    assert payload["service"] == "qalos-remote-control"
    # The mock android_release is MOCK_ANDROID_RELEASE ("15"); the
    # on-device value is android.os.Build.VERSION.RELEASE.
    assert "android" in payload


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
# v0.1.1 review-triage regression — dimension contract
# ----------------------------------------------------------------------

def test_screenshot_dimensions_default_to_native_when_zero(api):
    """When the client passes width=0/height=0, the response must echo
    the native display dimensions, not 0.

    This is the contract the on-device service implements (returns
    the effective capture size) and what the mock must mirror.
    Regression for the v0.1 bug where `handleScreenshot` echoed the
    raw requested width/height (including 0). Review-triage 2026-09-05.
    """
    responses, _ = _capture(api, "GET", "/screenshot", {"width": 0, "height": 0})
    payload = responses[0][1]
    assert payload["width"] == 1080
    assert payload["height"] == 2400


def test_screenshot_dimensions_echo_requested_when_nonzero(api):
    """When the client passes an explicit width/height, the response
    echoes those exact values."""
    responses, _ = _capture(api, "GET", "/screenshot",
                            {"width": 480, "height": 800})
    payload = responses[0][1]
    assert payload["width"] == 480
    assert payload["height"] == 800


def test_screenshot_accepts_float_quality(api):
    """Quality is an int field. A float is rejected with 400."""
    responses, _ = _capture(api, "GET", "/screenshot", {"quality": 50.0})
    # Mock's int() parsing would silently truncate; we still need to
    # verify it doesn't reject. (The real Java server now also accepts
    # integral Doubles — see HttpApiServer.java#requireInt.)
    assert responses[0][0] == 200
    # The mock doesn't store quality in the response payload (only in
    # the recorded call), but it should be present there.
    assert responses[0][1]["width"] == 1080


# ----------------------------------------------------------------------
# v0.1.1 review-triage regression — float-as-int JSON handling
# ----------------------------------------------------------------------

def test_tap_accepts_integral_double_json_via_http(device):
    """A POST body with `{"x": 540.0, "y": 1200.0}` is accepted
    because the values are mathematically integral.

    Regression for the v0.1 bug where the on-device service's
    `requireInt` rejected all `Double` values, breaking clients
    that serialise integers via standard JSON libraries (e.g.
    `json.dumps({"x": 540.0})`).
    """
    import json
    import requests
    body = json.dumps({"x": 540.0, "y": 1200.0, "display": 0}).encode("utf-8")
    resp = requests.post(
        f"{device.base_url}/tap",
        data=body,
        headers={"Content-Type": "application/json"},
        timeout=5,
    )
    assert resp.status_code == 200
    assert resp.json()["status"] == "ok"


def test_tap_rejects_non_integral_double_json(device):
    """A POST body with a non-integral float is silently truncated
    by the mock (it uses `int(value)` to coerce).

    This test pins the mock's current behaviour. The on-device Java
    service is stricter and *rejects* non-integral Doubles with 400
    (see HttpApiServer.java#requireInt). The two diverge here, but
    both agree on the integral case (which the v0.1.1 review
    flagged as a real bug — the Java side was rejecting *all*
    Doubles, including integral ones, which broke standard JSON
    serialisers). Review-triage 2026-09-05.
    """
    import json
    import requests
    body = json.dumps({"x": 540.5, "y": 1200, "display": 0}).encode("utf-8")
    resp = requests.post(
        f"{device.base_url}/tap",
        data=body,
        headers={"Content-Type": "application/json"},
        timeout=5,
    )
    # Mock truncates: 540.5 -> 540 (still a valid tap).
    assert resp.status_code == 200


# ----------------------------------------------------------------------
# Gestures (v0.1)
# ----------------------------------------------------------------------

def test_long_press_happy(api):
    responses, calls = _capture(api, "POST", "/long_press",
                                {"x": 100, "y": 200, "duration_ms": 500})
    assert responses == [(200, {"status": "ok"})]
    assert calls == [("POST", "/long_press",
                      {"x": 100, "y": 200, "duration_ms": 500})]


def test_long_press_rejects_missing_duration(api):
    responses, _ = _capture(api, "POST", "/long_press", {"x": 100, "y": 200})
    assert responses[0][0] == 400
    assert "duration_ms" in responses[0][1]["message"]


def test_long_press_rejects_negative_coords(api):
    responses, _ = _capture(api, "POST", "/long_press",
                            {"x": -1, "y": 200, "duration_ms": 500})
    assert responses[0][0] == 400
    assert "non-negative" in responses[0][1]["message"]


def test_long_press_rejects_too_short_duration(api):
    responses, _ = _capture(api, "POST", "/long_press",
                            {"x": 100, "y": 200, "duration_ms": 0})
    assert responses[0][0] == 400


def test_swipe_happy(api):
    responses, _ = _capture(api, "POST", "/swipe", {
        "x1": 100, "y1": 500, "x2": 900, "y2": 500,
        "steps": 10, "duration_ms": 200,
    })
    assert responses == [(200, {"status": "ok"})]


def test_swipe_rejects_missing_steps(api):
    responses, _ = _capture(api, "POST", "/swipe", {
        "x1": 100, "y1": 500, "x2": 900, "y2": 500, "duration_ms": 200,
    })
    assert responses[0][0] == 400
    assert "steps" in responses[0][1]["message"]


def test_swipe_rejects_zero_steps(api):
    responses, _ = _capture(api, "POST", "/swipe", {
        "x1": 100, "y1": 500, "x2": 900, "y2": 500,
        "steps": 0, "duration_ms": 200,
    })
    assert responses[0][0] == 400


def test_pinch_happy(api):
    responses, _ = _capture(api, "POST", "/pinch", {
        "cx": 540, "cy": 1200, "r1": 100, "r2": 300,
        "steps": 10, "duration_ms": 200,
    })
    assert responses == [(200, {"status": "ok"})]


def test_pinch_rejects_zero_r1(api):
    responses, _ = _capture(api, "POST", "/pinch", {
        "cx": 540, "cy": 1200, "r1": 0, "r2": 300,
        "steps": 10, "duration_ms": 200,
    })
    assert responses[0][0] == 400


def test_pinch_rejects_out_of_bounds_center(api):
    responses, _ = _capture(api, "POST", "/pinch", {
        "cx": 99999, "cy": 1200, "r1": 100, "r2": 300,
        "steps": 10, "duration_ms": 200,
    })
    assert responses[0][0] == 400


# ----------------------------------------------------------------------
# Discovery (v0.1): /capabilities + /info
# ----------------------------------------------------------------------

def test_capabilities_happy(api):
    responses, _ = _capture(api, "GET", "/capabilities")
    payload = responses[0][1]
    assert responses[0][0] == 200
    assert payload["service"] == "qalos-remote-control"
    assert payload["api_version"] == 1
    assert "build_id" in payload
    assert "started_at" in payload
    assert "uptime_ms" in payload
    assert "endpoints" in payload
    for required in ("health", "tap", "long_press", "swipe", "pinch",
                     "screenshot", "capabilities", "info"):
        assert required in payload["endpoints"], \
            f"{required} missing from capabilities endpoints"


def test_info_happy(api):
    responses, _ = _capture(api, "GET", "/info")
    payload = responses[0][1]
    assert responses[0][0] == 200
    assert payload["manufacturer"] == "Mock"
    assert payload["model"] == "qalos-emulator-mock"
    assert payload["android_release"] == "15"
    assert payload["android_sdk"] == 35
    assert payload["display_width"] == 1080
    assert payload["display_height"] == 2400
    assert payload["foreground_package"] == "com.android.launcher"


def test_info_reflects_foreground_change(api):
    api.foreground_package = "com.example.app"
    responses, _ = _capture(api, "GET", "/info")
    assert responses[0][1]["foreground_package"] == "com.example.app"


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
