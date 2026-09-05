# SPDX-License-Identifier: MIT
"""End-to-end tests for the qa-lab-os Python client against the mock server."""

from __future__ import annotations

import pytest
import requests

from client import DisplaySize, QaLabDevice, QaLabError


# ----------------------------------------------------------------------
# Display + queries
# ----------------------------------------------------------------------

def test_health_returns_dict(device):
    payload = device.health()
    assert payload["status"] == "ok"
    # /health is a liveness probe; device metadata lives in /info.
    # We only assert the well-known fields are present.
    assert "service" in payload
    assert "android" in payload


def test_display_size_is_cached(device):
    first = device.display_size
    second = device.display_size
    assert first is second  # same dataclass returned on second call
    assert first == DisplaySize(width=1080, height=2400)


def test_width_and_height_properties(device):
    assert device.width == 1080
    assert device.height == 2400


def test_foreground_package(device, server):
    assert device.foreground_package == "com.android.launcher"
    server.api.foreground_package = "com.example.app"
    assert device.foreground_package == "com.example.app"


def test_foreground_package_empty_string(device, server):
    server.api.foreground_package = ""
    assert device.foreground_package == ""


# ----------------------------------------------------------------------
# Input
# ----------------------------------------------------------------------

def test_tap_records_call(device, server):
    device.tap(100, 200)
    assert server.api.calls == [("POST", "/tap", {"x": 100, "y": 200, "display": 0})]


def test_tap_with_explicit_display(device, server):
    device.tap(10, 20, display=2)
    assert server.api.calls[-1] == ("POST", "/tap", {"x": 10, "y": 20, "display": 2})


def test_tap_rejects_negative_coordinates_client_side(device, server):
    """Negative coordinates are caught by the client before any HTTP call."""
    with pytest.raises(ValueError):
        device.tap(-1, 0)
    with pytest.raises(ValueError):
        device.tap(0, -1)
    assert server.api.calls == []


def test_tap_rejects_out_of_bounds_on_server(device, server):
    with pytest.raises(QaLabError) as excinfo:
        device.tap(99999, 0)
    assert "outside display" in str(excinfo.value)


def test_tap_relative_uses_display_size(device, server):
    device.tap_relative(0.5, 0.5)
    # Mock display is 1080x2400
    assert server.api.calls[-1][2] == {"x": 540, "y": 1200, "display": 0}


def test_tap_relative_rejects_out_of_range(device):
    with pytest.raises(ValueError):
        device.tap_relative(-0.1, 0.5)
    with pytest.raises(ValueError):
        device.tap_relative(0.5, 1.5)


def test_type_text_records_call(device, server):
    device.type_text("hello")
    assert server.api.calls == [("POST", "/type", {"text": "hello"})]


def test_type_text_rejects_non_string(device):
    with pytest.raises(TypeError):
        device.type_text(123)  # type: ignore[arg-type]


def test_type_text_rejects_too_long(device):
    with pytest.raises(ValueError):
        device.type_text("a" * 1025)


def test_key_default_is_press(device, server):
    device.key(4)
    assert server.api.calls == [("POST", "/key", {"key_code": 4, "down": True})]


def test_key_release(device, server):
    device.key(4, down=False)
    assert server.api.calls == [("POST", "/key", {"key_code": 4, "down": False})]


# ----------------------------------------------------------------------
# Gestures (v0.1)
# ----------------------------------------------------------------------

def test_long_press_records_call(device, server):
    device.long_press(540, 1200, 500)
    assert server.api.calls == [
        ("POST", "/long_press", {"x": 540, "y": 1200, "duration_ms": 500, "display": 0})
    ]


def test_long_press_rejects_negative_coordinates_client_side(device, server):
    with pytest.raises(ValueError):
        device.long_press(-1, 0, 500)
    with pytest.raises(ValueError):
        device.long_press(0, -1, 500)
    assert server.api.calls == []


def test_long_press_rejects_too_short_duration_client_side(device, server):
    with pytest.raises(ValueError):
        device.long_press(100, 100, 0)
    assert server.api.calls == []


def test_long_press_rejects_out_of_bounds_on_server(device, server):
    with pytest.raises(QaLabError) as excinfo:
        device.long_press(99999, 0, 500)
    assert "outside display" in str(excinfo.value)


def test_swipe_records_call(device, server):
    device.swipe(100, 500, 900, 500, steps=10, duration_ms=200)
    assert server.api.calls == [
        ("POST", "/swipe", {
            "x1": 100, "y1": 500, "x2": 900, "y2": 500,
            "steps": 10, "duration_ms": 200, "display": 0,
        })
    ]


def test_swipe_rejects_non_monotonic_steps(device, server):
    with pytest.raises(ValueError):
        device.swipe(0, 0, 100, 100, steps=0)
    assert server.api.calls == []


def test_swipe_rejects_out_of_bounds_on_server(device, server):
    with pytest.raises(QaLabError) as excinfo:
        device.swipe(0, 0, 99999, 0)
    assert "outside display" in str(excinfo.value)


def test_pinch_records_call(device, server):
    device.pinch(540, 1200, 100, 300, steps=10, duration_ms=200)
    assert server.api.calls == [
        ("POST", "/pinch", {
            "cx": 540, "cy": 1200, "r1": 100, "r2": 300,
            "steps": 10, "duration_ms": 200, "display": 0,
        })
    ]


def test_pinch_rejects_zero_radius(device, server):
    with pytest.raises(ValueError):
        device.pinch(540, 1200, 0, 100)
    with pytest.raises(ValueError):
        device.pinch(540, 1200, 100, 0)
    assert server.api.calls == []


# ----------------------------------------------------------------------
# v0.1.1 review-triage regressions
# ----------------------------------------------------------------------

def test_pinch_rejects_negative_center_client_side(device, server):
    """Negative (cx, cy) is caught by the client before any HTTP call.

    Regression for the v0.1.1 client-side validation gap. The server
    was already catching it (via the extreme-points check), but the
    client should pre-validate the centre coordinates the same way
    it does for tap/long_press.
    """
    with pytest.raises(ValueError):
        device.pinch(-1, 1200, 100, 300)
    with pytest.raises(ValueError):
        device.pinch(540, -1, 100, 300)
    assert server.api.calls == []


def test_long_press_rejects_overlong_duration_client_side(device, server):
    """duration_ms > MAX_LONG_PRESS_MS is rejected client-side.

    Regression for the v0.1.1 client-side upper-bound check.
    """
    from client import MAX_LONG_PRESS_MS
    with pytest.raises(ValueError):
        device.long_press(540, 1200, MAX_LONG_PRESS_MS + 1)
    assert server.api.calls == []


def test_swipe_rejects_overlong_duration_client_side(device, server):
    """duration_ms > MAX_GESTURE_DURATION_MS is rejected client-side."""
    from client import MAX_GESTURE_DURATION_MS
    with pytest.raises(ValueError):
        device.swipe(0, 0, 100, 100, steps=10,
                     duration_ms=MAX_GESTURE_DURATION_MS + 1)
    assert server.api.calls == []


def test_swipe_rejects_too_many_steps_client_side(device, server):
    """steps > MAX_GESTURE_STEPS is rejected client-side."""
    from client import MAX_GESTURE_STEPS
    with pytest.raises(ValueError):
        device.swipe(0, 0, 100, 100, steps=MAX_GESTURE_STEPS + 1,
                     duration_ms=200)
    assert server.api.calls == []


def test_pinch_rejects_too_many_steps_client_side(device, server):
    """steps > MAX_GESTURE_STEPS is rejected client-side."""
    from client import MAX_GESTURE_STEPS
    with pytest.raises(ValueError):
        device.pinch(540, 1200, 100, 300, steps=MAX_GESTURE_STEPS + 1,
                     duration_ms=200)
    assert server.api.calls == []


def test_invalidate_cache_clears_all_caches(device, server):
    """invalidate_cache() forces the next access to re-fetch.

    Regression for the v0.1 cache-never-invalidated issue. Without
    this, a rotation or build upgrade would leave stale data.
    """
    # Warm all three caches.
    _ = device.display_size
    _ = device.capabilities
    _ = device.info
    # The mock records calls only on /tap etc., but the public
    # /display, /capabilities, /info calls go through the same HTTP
    # path. We can observe a re-fetch by mutating the mock state
    # BEFORE invalidating and verifying the second access picks up
    # the mutation.
    server.api.foreground_package = "com.example.app"
    # Cache still has the old (launcher) value.
    assert device.info.foreground_package == "com.android.launcher"
    # After invalidating, the next access re-fetches.
    device.invalidate_cache()
    assert device.info.foreground_package == "com.example.app"


# ----------------------------------------------------------------------
# Discovery (v0.1): /capabilities + /info
# ----------------------------------------------------------------------

def test_capabilities_returns_service_info(device):
    cap = device.capabilities
    assert cap.service == "qalos-remote-control"
    assert isinstance(cap.api_version, int)
    assert cap.api_version >= 1
    # build_id is a non-empty string field (mock returns a fixed value).
    assert isinstance(cap.build_id, str) and cap.build_id
    assert isinstance(cap.endpoints, list)
    # The mock advertises the full endpoint list including the
    # gestures we just added.
    for required in ("health", "tap", "long_press", "swipe", "pinch",
                     "screenshot", "capabilities", "info"):
        assert required in cap.endpoints, f"{required} missing from endpoints"


def test_capabilities_is_cached(device):
    a = device.capabilities
    b = device.capabilities
    assert a is b


def test_info_returns_device_info(device):
    info = device.info
    assert info.manufacturer == "Mock"
    assert info.model == "qalos-emulator-mock"
    assert info.android_release == "15"
    assert info.android_sdk == 35
    assert info.display_width == 1080
    assert info.display_height == 2400


def test_info_is_cached(device):
    a = device.info
    b = device.info
    assert a is b


def test_alive_returns_true_when_service_is_up(device):
    assert device.alive() is True


def test_alive_returns_false_when_service_is_down():
    """Connect to a port that is closed. alive() must not raise."""
    import socket
    # Bind-and-close to grab a port that nothing is listening on.
    with socket.socket(socket.AF_INET, socket.SOCK_STREAM) as s:
        s.bind(("127.0.0.1", 0))
        port = s.getsockname()[1]
    # That port is now free, so a connect attempt will be refused.
    from client import QaLabDevice
    d = QaLabDevice("127.0.0.1", port, timeout_s=2.0)
    try:
        assert d.alive() is False
    finally:
        d.close()


# ----------------------------------------------------------------------
# App lifecycle
# ----------------------------------------------------------------------

def test_launch(device, server):
    device.launch("com.example.app")
    assert server.api.calls == [("POST", "/launch", {"package": "com.example.app"})]


def test_launch_rejects_empty_string(device):
    with pytest.raises(ValueError):
        device.launch("")


def test_force_stop(device, server):
    device.force_stop("com.example.app")
    assert server.api.calls == [("POST", "/force_stop", {"package": "com.example.app"})]


# ----------------------------------------------------------------------
# Screenshot
# ----------------------------------------------------------------------

def test_screenshot_returns_pil_image(device):
    from PIL import Image
    image = device.screenshot()
    assert isinstance(image, Image.Image)
    # The mock returns a 1x1 placeholder PNG; the real on-device
    # service returns the requested resolution. We only assert that
    # the client opens a valid image.
    assert image.size == (1, 1)


def test_screenshot_with_quality(device, server):
    device.screenshot(quality=50)
    assert server.api.calls[-1] == (
        "GET",
        "/screenshot",
        {"width": 0, "height": 0, "display": 0, "quality": 50},
    )


def test_screenshot_with_dimensions(device, server):
    device.screenshot(width=480, height=800)
    assert server.api.calls[-1] == (
        "GET",
        "/screenshot",
        {"width": 480, "height": 800, "display": 0, "quality": 85},
    )


def test_screenshot_rejects_invalid_quality_client_side(device, server):
    with pytest.raises(ValueError):
        device.screenshot(quality=0)
    with pytest.raises(ValueError):
        device.screenshot(quality=200)
    assert server.api.calls == []


def test_screenshot_url_decodes_query_params(device, server):
    """Query params are URL-decoded before the int-parse.

    Regression test for M-B: the mock used to receive the raw
    `%20300` string instead of `300` (as an int) when a client
    sent a percent-encoded value.
    """
    # Direct POST with a percent-encoded value, bypassing the
    # Python client so the URL encoding actually reaches the server.
    import requests
    resp = requests.get(
        f"{device.base_url}/screenshot?width=%20300&quality=85",
        timeout=5,
    )
    assert resp.status_code == 200
    # The recorded call should have width=300 (decoded then int-parsed),
    # not the string " 300" or "%20300".
    last = server.api.calls[-1]
    assert last[0] == "GET"
    assert last[1] == "/screenshot"
    assert last[2]["width"] == 300
    assert last[2]["quality"] == 85


# ----------------------------------------------------------------------
# Error handling — exercised via direct HTTP so we can see the raw
# response shape, not the client-side wrappers.
# ----------------------------------------------------------------------

def _raw_post(device, path: str, body: dict) -> requests.Response:
    # Use the public base_url so we do not depend on private state.
    return requests.post(f"{device.base_url}{path}", json=body, timeout=5)


def test_missing_required_field_returns_400(device):
    resp = _raw_post(device, "/tap", {})
    assert resp.status_code == 400
    body = resp.json()
    assert body["status"] == "error"
    assert "x" in body["message"]


def test_unknown_endpoint_returns_404(device):
    resp = _raw_post(device, "/nope", {})
    assert resp.status_code == 404
    body = resp.json()
    assert body["status"] == "error"
    assert "no such endpoint" in body["message"]


def test_malformed_json_returns_400(device):
    resp = requests.post(
        f"{device.base_url}/tap",
        data="not json",
        headers={"Content-Type": "application/json"},
        timeout=5,
    )
    assert resp.status_code == 400
    assert resp.json()["status"] == "error"
