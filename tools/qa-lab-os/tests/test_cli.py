# SPDX-License-Identifier: MIT
"""Smoke tests for the qalos CLI subcommands.

These tests run the CLI as a subprocess against the mock server
to verify argument parsing, output formatting, and exit codes
without taking a dependency on argparse internals.
"""

from __future__ import annotations

import json
import subprocess
import sys

import pytest

from mock_server import MockRemoteControlServer


@pytest.fixture
def mock():
    with MockRemoteControlServer() as srv:
        yield srv


def _run_cli(*args: str) -> subprocess.CompletedProcess:
    """Invoke `python -m cli ...` (CLI is a py-module, not a script yet)."""
    return subprocess.run(
        [sys.executable, "-m", "cli", *args],
        capture_output=True, text=True, timeout=15,
        cwd=".",  # tests/ is the default cwd for pytest; this is a hint
    )


def test_status_subcommand_prints_capabilities(mock):
    proc = _run_cli("status", "--host", "localhost",
                    "--port", str(mock.port), "--timeout", "5")
    assert proc.returncode == 0, proc.stderr
    assert "qalos-remote-control" in proc.stdout
    assert "Endpoints" in proc.stdout


def test_info_subcommand_prints_device_info(mock):
    proc = _run_cli("info", "--host", "localhost",
                    "--port", str(mock.port), "--timeout", "5")
    assert proc.returncode == 0, proc.stderr
    assert "Mock" in proc.stdout  # manufacturer
    assert "qalos-emulator-mock" in proc.stdout  # model
    assert "android_release" in proc.stdout.lower() or "Android" in proc.stdout


def test_tap_subcommand_posts(mock):
    proc = _run_cli("tap", "540", "1200",
                    "--host", "localhost", "--port", str(mock.port))
    assert proc.returncode == 0, proc.stderr
    assert "tap (540, 1200)" in proc.stdout
    assert mock.api.calls == [
        ("POST", "/tap", {"x": 540, "y": 1200, "display": 0})
    ]


def test_long_press_subcommand_posts(mock):
    proc = _run_cli("long-press", "100", "200", "500",
                    "--host", "localhost", "--port", str(mock.port))
    assert proc.returncode == 0, proc.stderr
    assert "long_press (100, 200) for 500ms" in proc.stdout


def test_swipe_subcommand_posts(mock):
    proc = _run_cli("swipe", "0", "0", "100", "100",
                    "--steps", "5", "--duration-ms", "100",
                    "--host", "localhost", "--port", str(mock.port))
    assert proc.returncode == 0, proc.stderr
    assert "swipe (0, 0) -> (100, 100)" in proc.stdout


def test_pinch_subcommand_posts(mock):
    proc = _run_cli("pinch", "540", "1200", "100", "200",
                    "--steps", "5", "--duration-ms", "100",
                    "--host", "localhost", "--port", str(mock.port))
    assert proc.returncode == 0, proc.stderr
    assert "pinch at (540, 1200)" in proc.stdout


def test_status_returns_nonzero_for_unreachable_service():
    """A connect-refused on localhost:1 should exit non-zero."""
    proc = _run_cli("status", "--host", "127.0.0.1", "--port", "1", "--timeout", "1")
    assert proc.returncode != 0
    assert "not responding" in proc.stderr or "error" in proc.stderr.lower()


def test_wait_until_alive_succeeds_when_service_responds(mock):
    proc = _run_cli("wait-until-alive",
                    "--host", "localhost", "--port", str(mock.port),
                    "--timeout", "5", "--interval", "0.5")
    assert proc.returncode == 0, proc.stderr
    assert "is alive" in proc.stdout


def test_wait_until_alive_times_out_for_unreachable():
    proc = _run_cli("wait-until-alive",
                    "--host", "127.0.0.1", "--port", "1",
                    "--timeout", "1", "--interval", "0.3")
    assert proc.returncode != 0
    assert "not alive" in proc.stderr


def test_screenshot_subcommand_saves_file(mock, tmp_path):
    out = tmp_path / "screen.png"
    proc = _run_cli("screenshot", str(out),
                    "--host", "localhost", "--port", str(mock.port))
    assert proc.returncode == 0, proc.stderr
    assert out.exists()
    assert out.stat().st_size > 0
