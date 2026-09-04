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
    assert "device" in payload
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
