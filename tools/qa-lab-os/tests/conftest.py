# SPDX-License-Identifier: MIT
"""Shared pytest fixtures for the qa-lab-os test suite."""

from __future__ import annotations

import sys
from pathlib import Path

import pytest

# Allow `import client` and `import mock_server` from the parent
# directory without requiring the package to be installed. CI installs
# the package; local dev just runs `pytest` from tools/qa-lab-os.
_THIS_DIR = Path(__file__).resolve().parent
_PARENT = _THIS_DIR.parent
if str(_PARENT) not in sys.path:
    sys.path.insert(0, str(_PARENT))

from mock_server import MockRemoteControlServer  # noqa: E402


@pytest.fixture
def server() -> MockRemoteControlServer:
    """Yield a running mock server on a random free port."""
    with MockRemoteControlServer() as srv:
        yield srv


@pytest.fixture
def device(server: MockRemoteControlServer):
    """Yield a QaLabDevice wired to the mock server."""
    # Imported lazily so the test file can also use the fixture even
    # if the package is not installed.
    from client import QaLabDevice
    with QaLabDevice("127.0.0.1", server.port) as dev:
        yield dev
