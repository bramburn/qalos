# SPDX-License-Identifier: MIT
"""QA Lab OS Python client SDK.

Drives a device running the qalos RemoteControlService. Communicates
over plain HTTP/JSON on `localhost:9000` (tunneled via
``adb forward tcp:9000 tcp:9000`` on the host side).

Example
-------
::

    from qa_lab_os import QaLabDevice

    with QaLabDevice("localhost", 9000) as device:
        device.tap(540, 1200)
        device.type_text("hello")
        image = device.screenshot()
        image.save("screen.png")
        print(device.foreground_package)
"""

from __future__ import annotations

import base64
import io
import logging
from dataclasses import dataclass, field
from typing import Any, Tuple

import requests
from PIL import Image

LOGGER = logging.getLogger(__name__)

DEFAULT_PORT = 9000
DEFAULT_TIMEOUT_S = 30.0
DEFAULT_HEALTH_TIMEOUT_S = 2.0


class QaLabError(RuntimeError):
    """Raised when the on-device service returns a non-OK response."""


@dataclass(frozen=True)
class DisplaySize:
    """Display size in pixels."""

    width: int
    height: int

    def as_tuple(self) -> Tuple[int, int]:
        return (self.width, self.height)


@dataclass(frozen=True)
class ServiceInfo:
    """On-device service metadata (from /capabilities)."""

    service: str
    service_version: str
    api_version: int
    build_id: str
    started_at: int
    uptime_ms: int
    endpoints: list[str] = field(default_factory=list)


@dataclass(frozen=True)
class DeviceInfo:
    """On-device metadata (from /info)."""

    manufacturer: str
    model: str
    android_release: str
    android_sdk: int
    display_width: int
    display_height: int
    foreground_package: str


class QaLabDevice:
    """Client for the qalos RemoteControlService HTTP/JSON API.

    The instance is safe to share across threads; the underlying
    ``requests.Session`` is thread-safe for our usage (each call
    issues one request).
    """

    def __init__(
        self,
        host: str = "localhost",
        port: int = DEFAULT_PORT,
        *,
        timeout_s: float = DEFAULT_TIMEOUT_S,
    ) -> None:
        self._base = f"http://{host}:{port}"
        self._timeout_s = timeout_s
        self._session = requests.Session()
        self._display_size: DisplaySize | None = None
        self._service_info: ServiceInfo | None = None
        self._device_info: DeviceInfo | None = None

    # ------------------------------------------------------------------
    # Context manager
    # ------------------------------------------------------------------

    def __enter__(self) -> "QaLabDevice":
        return self

    def __exit__(self, exc_type, exc, tb) -> None:
        self.close()

    def close(self) -> None:
        self._session.close()

    # ------------------------------------------------------------------
    # Public address
    # ------------------------------------------------------------------

    @property
    def base_url(self) -> str:
        """The base URL of the remote service (e.g. `http://localhost:9000`).

        Useful for tests and tools that need to issue raw HTTP calls.
        """
        return self._base

    # ------------------------------------------------------------------
    # Display + queries
    # ------------------------------------------------------------------

    @property
    def display_size(self) -> DisplaySize:
        if self._display_size is None:
            self._display_size = self._query_display_size()
        return self._display_size

    @property
    def width(self) -> int:
        return self.display_size.width

    @property
    def height(self) -> int:
        return self.display_size.height

    def _query_display_size(self) -> DisplaySize:
        payload = self._get("/display")
        return DisplaySize(int(payload["width"]), int(payload["height"]))

    def health(self) -> dict:
        """Return the ``/health`` payload as a dict.

        Raises :class:`QaLabError` on a non-200 response.
        """
        return self._get("/health")

    @property
    def foreground_package(self) -> str:
        """Return the package name of the top focused task.

        Returns an empty string if the home screen is focused.
        """
        payload = self._get("/foreground")
        return str(payload.get("package", ""))

    @property
    def capabilities(self) -> ServiceInfo:
        """Cached call to ``/capabilities``."""
        if self._service_info is None:
            self._service_info = self._query_capabilities()
        return self._service_info

    @property
    def info(self) -> DeviceInfo:
        """Cached call to ``/info``."""
        if self._device_info is None:
            self._device_info = self._query_info()
        return self._device_info

    def _query_capabilities(self) -> ServiceInfo:
        payload = self._get("/capabilities")
        return ServiceInfo(
            service=str(payload.get("service", "")),
            service_version=str(payload.get("service_version", "")),
            api_version=int(payload.get("api_version", 0)),
            build_id=str(payload.get("build_id", "")),
            started_at=int(payload.get("started_at", 0)),
            uptime_ms=int(payload.get("uptime_ms", 0)),
            endpoints=list(payload.get("endpoints", []) or []),
        )

    def _query_info(self) -> DeviceInfo:
        payload = self._get("/info")
        return DeviceInfo(
            manufacturer=str(payload.get("manufacturer", "")),
            model=str(payload.get("model", "")),
            android_release=str(payload.get("android_release", "")),
            android_sdk=int(payload.get("android_sdk", 0)),
            display_width=int(payload.get("display_width", 0)),
            display_height=int(payload.get("display_height", 0)),
            foreground_package=str(payload.get("foreground_package", "")),
        )

    def alive(self, timeout_s: float = DEFAULT_HEALTH_TIMEOUT_S) -> bool:
        """Return True iff ``/health`` returns 200 within ``timeout_s``."""
        try:
            response = self._session.get(f"{self._base}/health",
                                         timeout=timeout_s)
            return response.status_code == 200
        except requests.RequestException:
            return False

    # ------------------------------------------------------------------
    # Input
    # ------------------------------------------------------------------

    def tap(self, x: int, y: int, *, display: int = 0) -> None:
        """Single tap at ``(x, y)`` on ``display``.

        Raises :class:`ValueError` if ``x`` or ``y`` is negative.
        Raises :class:`QaLabError` if the on-device service rejects
        the coordinates.
        """
        if x < 0 or y < 0:
            raise ValueError(f"coordinates must be non-negative, got ({x}, {y})")
        self._post("/tap", {"x": int(x), "y": int(y), "display": int(display)})

    def tap_relative(self, rx: float, ry: float, *, display: int = 0) -> None:
        """Tap at relative coordinates in ``[0.0, 1.0]``.

        Converts to absolute pixel coordinates using
        :attr:`display_size` before calling :meth:`tap`.
        """
        if not (0.0 <= rx <= 1.0) or not (0.0 <= ry <= 1.0):
            raise ValueError(f"relative coords must be in [0.0, 1.0], got ({rx}, {ry})")
        w, h = self.display_size.as_tuple()
        self.tap(int(w * rx), int(h * ry), display=display)

    def type_text(self, text: str) -> None:
        """Type ``text`` into the focused field."""
        if not isinstance(text, str):
            raise TypeError(f"text must be str, got {type(text).__name__}")
        if len(text) > 1024:
            raise ValueError("text too long (>1024 chars)")
        self._post("/type", {"text": text})

    def key(self, key_code: int, *, down: bool = True) -> None:
        """Send a hardware key event.

        ``key_code`` is an Android ``KeyEvent.KEYCODE_*`` constant,
        e.g. ``4`` for ``KEYCODE_BACK``.
        """
        self._post("/key", {"key_code": int(key_code), "down": bool(down)})

    def long_press(self, x: int, y: int, duration_ms: int,
                   *, display: int = 0) -> None:
        """Press and hold ``(x, y)`` for ``duration_ms`` milliseconds.

        Useful for opening context menus. ``duration_ms`` is clamped
        to ``[1, 5000]`` on-device; out-of-range values are not an
        error, they are silently clamped.
        """
        if x < 0 or y < 0:
            raise ValueError(f"coordinates must be non-negative, got ({x}, {y})")
        if duration_ms < 1:
            raise ValueError(f"duration_ms must be >= 1, got {duration_ms}")
        self._post("/long_press", {
            "x": int(x), "y": int(y),
            "duration_ms": int(duration_ms),
            "display": int(display),
        })

    def swipe(self, x1: int, y1: int, x2: int, y2: int,
              steps: int = 20, duration_ms: int = 300,
              *, display: int = 0) -> None:
        """Drag from ``(x1, y1)`` to ``(x2, y2)`` over ``duration_ms``.

        ``steps`` intermediate ``ACTION_MOVE`` events are injected;
        more steps = smoother animation. Clamped to ``[1, 200]`` and
        ``[1, 10000]`` on-device.
        """
        for coord in (x1, y1, x2, y2):
            if coord < 0:
                raise ValueError(f"coordinates must be non-negative, got {coord}")
        if steps < 1:
            raise ValueError(f"steps must be >= 1, got {steps}")
        if duration_ms < 1:
            raise ValueError(f"duration_ms must be >= 1, got {duration_ms}")
        self._post("/swipe", {
            "x1": int(x1), "y1": int(y1),
            "x2": int(x2), "y2": int(y2),
            "steps": int(steps),
            "duration_ms": int(duration_ms),
            "display": int(display),
        })

    def pinch(self, cx: int, cy: int, r1: int, r2: int,
              steps: int = 20, duration_ms: int = 300,
              *, display: int = 0) -> None:
        """Two-finger zoom centered at ``(cx, cy)``.

        ``r1`` is the starting radius (each pointer at cx-r1 and cx+r1).
        ``r2`` is the ending radius. A zoom-in: r2 > r1. A zoom-out:
        r2 < r1. Clamped to ``[1, 200]`` steps and ``[1, 10000]`` ms.
        """
        if r1 < 1 or r2 < 1:
            raise ValueError(f"radii must be >= 1, got r1={r1} r2={r2}")
        if steps < 1:
            raise ValueError(f"steps must be >= 1, got {steps}")
        if duration_ms < 1:
            raise ValueError(f"duration_ms must be >= 1, got {duration_ms}")
        self._post("/pinch", {
            "cx": int(cx), "cy": int(cy),
            "r1": int(r1), "r2": int(r2),
            "steps": int(steps),
            "duration_ms": int(duration_ms),
            "display": int(display),
        })

    # ------------------------------------------------------------------
    # App lifecycle
    # ------------------------------------------------------------------

    def launch(self, package: str) -> None:
        """Launch ``package`` in the foreground."""
        if not package:
            raise ValueError("package must be a non-empty string")
        self._post("/launch", {"package": package})

    def force_stop(self, package: str) -> None:
        """Force-stop ``package``."""
        if not package:
            raise ValueError("package must be a non-empty string")
        self._post("/force_stop", {"package": package})

    # ------------------------------------------------------------------
    # Screenshot
    # ------------------------------------------------------------------

    def screenshot(
        self,
        *,
        width: int = 0,
        height: int = 0,
        display: int = 0,
        quality: int = 85,
    ) -> Image.Image:
        """Capture a screenshot and return it as a :class:`PIL.Image.Image`.

        ``width`` and ``height`` of 0 mean "native display size".
        ``quality`` is the PNG compression level (1-100); 85 is a
        good LLM-friendly default.
        """
        if not (1 <= quality <= 100):
            raise ValueError(f"quality must be in [1, 100], got {quality}")
        payload = self._get(
            "/screenshot",
            params={
                "width": int(width),
                "height": int(height),
                "display": int(display),
                "quality": int(quality),
            },
        )
        image_b64 = payload.get("image")
        if not image_b64:
            raise QaLabError("screenshot response had no image field")
        raw = base64.b64decode(image_b64)
        return Image.open(io.BytesIO(raw))

    # ------------------------------------------------------------------
    # HTTP plumbing
    # ------------------------------------------------------------------

    def _get(self, path: str, params: dict | None = None) -> dict:
        url = f"{self._base}{path}"
        try:
            response = self._session.get(url, params=params, timeout=self._timeout_s)
        except requests.RequestException as exc:
            raise QaLabError(f"GET {path} failed: {exc}") from exc
        return self._decode(response, path)

    def _post(self, path: str, body: dict) -> dict:
        url = f"{self._base}{path}"
        try:
            response = self._session.post(url, json=body, timeout=self._timeout_s)
        except requests.RequestException as exc:
            raise QaLabError(f"POST {path} failed: {exc}") from exc
        return self._decode(response, path)

    @staticmethod
    def _decode(response: requests.Response, path: str) -> dict:
        if response.status_code != 200:
            raise QaLabError(
                f"{path} returned HTTP {response.status_code}: {response.text[:200]}"
            )
        try:
            payload = response.json()
        except ValueError as exc:
            raise QaLabError(f"{path} returned non-JSON: {exc}") from exc
        if not isinstance(payload, dict):
            raise QaLabError(f"{path} returned non-object JSON: {type(payload).__name__}")
        if payload.get("status") == "error":
            raise QaLabError(f"{path} returned error: {payload.get('message')}")
        return payload
