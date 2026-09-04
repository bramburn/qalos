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
from dataclasses import dataclass
from typing import Tuple

import requests
from PIL import Image

LOGGER = logging.getLogger(__name__)

DEFAULT_PORT = 9000
DEFAULT_TIMEOUT_S = 30.0


class QaLabError(RuntimeError):
    """Raised when the on-device service returns a non-OK response."""


@dataclass(frozen=True)
class DisplaySize:
    """Display size in pixels."""

    width: int
    height: int

    def as_tuple(self) -> Tuple[int, int]:
        return (self.width, self.height)


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
