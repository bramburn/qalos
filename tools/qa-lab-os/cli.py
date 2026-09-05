# SPDX-License-Identifier: MIT
"""qalos — the QA Lab OS console client.

A thin command-line wrapper around the Python client SDK. The
intended users are humans who want to drive a device quickly
without writing Python, and shell scripts that need to invoke
the device API.

Subcommands::

    qalos status                 — print /capabilities as a table
    qalos devices                — discover reachable qalos services
    qalos tap X Y                — POST /tap
    qalos long-press X Y MS      — POST /long_press
    qalos swipe X1 Y1 X2 Y2      — POST /swipe
    qalos pinch CX CY R1 R2      — POST /pinch
    qalos key CODE [--down/--up] — POST /key
    qalos type TEXT              — POST /type
    qalos launch PKG             — POST /launch
    qalos force-stop PKG         — POST /force_stop
    qalos screenshot OUT.png     — GET /screenshot, save to file
    qalos info                    — print /info as a table
    qalos forward [--port N]     — `adb forward tcp:N tcp:9000`
    qalos wait-until-alive       — poll /health until 200 or timeout
"""

from __future__ import annotations

import argparse
import json
import re
import subprocess
import sys
import time
from typing import List, Optional, Tuple

from client import DEFAULT_PORT, DisplaySize, QaLabDevice, QaLabError


def _print_table(rows: List[Tuple[str, ...]], headers: Tuple[str, ...]) -> None:
    """Print a left-aligned ASCII table to stdout."""
    widths = [len(h) for h in headers]
    for row in rows:
        for i, cell in enumerate(row):
            widths[i] = max(widths[i], len(str(cell)))
    sep = "-+-".join("-" * w for w in widths)
    print(" | ".join(h.ljust(w) for h, w in zip(headers, widths)))
    print(sep)
    for row in rows:
        print(" | ".join(str(c).ljust(w) for c, w in zip(row, widths)))


def _print_kv(pairs: List[Tuple[str, str]]) -> None:
    """Print a key/value list with aligned columns."""
    if not pairs:
        return
    width = max(len(k) for k, _ in pairs)
    for k, v in pairs:
        print(f"{k.ljust(width)} : {v}")


def _run_adb(args: List[str], timeout: int = 5) -> Tuple[int, str, str]:
    """Run an `adb` command, returning (returncode, stdout, stderr)."""
    try:
        proc = subprocess.run(
            ["adb", *args],
            capture_output=True, text=True, timeout=timeout,
        )
        return proc.returncode, proc.stdout, proc.stderr
    except FileNotFoundError:
        return 127, "", "adb not on PATH"
    except subprocess.TimeoutExpired:
        return 124, "", f"adb timed out after {timeout}s"


def _host_for(serial: Optional[str]) -> str:
    """Pick the default host for a given adb device serial.

    Per `adb forward` semantics, a serial-less `adb forward` applies
    to the only-connected device. Multi-device callers must pass
    `--serial` and we honour that by using the matching `localhost`
    port (set up by the caller via `qalos forward`).
    """
    return "localhost"


# ----------------------------------------------------------------------
# Subcommand handlers
# ----------------------------------------------------------------------


def cmd_status(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        if not device.alive(timeout_s=args.timeout):
            print(f"qalos at {args.host}:{args.port} is not responding",
                  file=sys.stderr)
            return 1
        cap = device.capabilities
        info = device.info
        print(f"qalos at {args.host}:{args.port}")
        _print_kv([
            ("service", cap.service),
            ("service_version", cap.service_version),
            ("api_version", str(cap.api_version)),
            ("build_id", cap.build_id),
            ("uptime_ms", str(cap.uptime_ms)),
            ("started_at", str(cap.started_at)),
            ("device", f"{info.manufacturer} {info.model}"),
            ("android_release", info.android_release),
            ("android_sdk", str(info.android_sdk)),
            ("display", f"{info.display_width}x{info.display_height}"),
            ("foreground_package", info.foreground_package),
        ])
        print()
        print("Endpoints:")
        for ep in cap.endpoints:
            print(f"  {ep}")
    return 0


def cmd_info(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        info = device.info
        _print_kv([
            ("manufacturer", info.manufacturer),
            ("model", info.model),
            ("android_release", info.android_release),
            ("android_sdk", str(info.android_sdk)),
            ("display", f"{info.display_width}x{info.display_height}"),
            ("foreground_package", info.foreground_package),
        ])
    return 0


def cmd_devices(args: argparse.Namespace) -> int:
    """Discover reachable qalos services.

    Runs `adb devices -l` and for each device probes localhost:9000..N
    (default 9010) for a qalos service. Prints a table.
    """
    rc, out, err = _run_adb(["devices", "-l"], timeout=10)
    if rc == 127:
        print("adb not found on PATH", file=sys.stderr)
        return 1
    if rc != 0:
        print(f"adb devices failed: {err.strip()}", file=sys.stderr)
        return 1
    rows: List[Tuple[str, ...]] = []
    port_lo, port_hi = args.port_range
    for line in out.splitlines():
        line = line.strip()
        if not line or line.startswith("List of devices"):
            continue
        # adb output: "<serial>  <state>  <colon-separated props>"
        parts = line.split()
        if len(parts) < 2:
            continue
        serial = parts[0]
        state = parts[1]
        if state != "device":
            rows.append((serial, state, "-", "-", "-", "no (not connected)"))
            continue
        # Probe ports.
        reachable: List[Tuple[int, dict]] = []
        for port in range(port_lo, port_hi + 1):
            probe = QaLabDevice("localhost", port, timeout_s=1.0)
            if probe.alive(timeout_s=1.0):
                try:
                    with probe:
                        cap = probe.capabilities
                        reachable.append((port, {
                            "build_id": cap.build_id,
                            "android": "-",
                            "manufacturer": "-",
                        }))
                except QaLabError:
                    pass
            probe.close()
        if not reachable:
            rows.append((serial, state, "-", "-", "-", "no (qalos not running)"))
        else:
            for port, info in reachable:
                # Augment with /info
                probe = QaLabDevice("localhost", port, timeout_s=2.0)
                try:
                    with probe:
                        device_info = probe.info
                        rows.append((
                            serial, state, str(port),
                            f"{device_info.manufacturer} {device_info.model}",
                            device_info.android_release,
                            f"yes (build {info['build_id']})",
                        ))
                except QaLabError:
                    rows.append((serial, state, str(port), "?", "?",
                                 f"yes (build {info['build_id']})"))
                finally:
                    probe.close()
    if not rows:
        print("No adb devices found.", file=sys.stderr)
        return 0
    _print_table(rows, ("serial", "state", "port", "device",
                         "android", "qalos"))
    return 0


def cmd_tap(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.tap(args.x, args.y, display=args.display)
    print(f"tap ({args.x}, {args.y}) on display {args.display}")
    return 0


def cmd_long_press(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.long_press(args.x, args.y, args.duration_ms,
                          display=args.display)
    print(f"long_press ({args.x}, {args.y}) for {args.duration_ms}ms")
    return 0


def cmd_swipe(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.swipe(args.x1, args.y1, args.x2, args.y2,
                     steps=args.steps, duration_ms=args.duration_ms,
                     display=args.display)
    print(f"swipe ({args.x1}, {args.y1}) -> ({args.x2}, {args.y2}) "
          f"in {args.steps} steps over {args.duration_ms}ms")
    return 0


def cmd_pinch(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.pinch(args.cx, args.cy, args.r1, args.r2,
                     steps=args.steps, duration_ms=args.duration_ms,
                     display=args.display)
    print(f"pinch at ({args.cx}, {args.cy}) r1={args.r1} r2={args.r2} "
          f"in {args.steps} steps over {args.duration_ms}ms")
    return 0


def cmd_key(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        # Default: press and release (a complete key event).
        device.key(args.key_code, down=True)
        if not args.no_release:
            time.sleep(0.05)
            device.key(args.key_code, down=False)
    print(f"key {args.key_code} pressed" + ("" if args.no_release else " + released"))
    return 0


def cmd_type(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.type_text(args.text)
    print(f"typed {len(args.text)} chars")
    return 0


def cmd_launch(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.launch(args.package)
    print(f"launched {args.package}")
    return 0


def cmd_force_stop(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        device.force_stop(args.package)
    print(f"force-stopped {args.package}")
    return 0


def cmd_screenshot(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=args.timeout)
    with device:
        image = device.screenshot(width=args.width, height=args.height,
                                  quality=args.quality)
        image.save(args.out_path)
    print(f"saved {args.out_path} ({image.size[0]}x{image.size[1]})")
    return 0


def cmd_forward(args: argparse.Namespace) -> int:
    """Set up `adb forward tcp:N tcp:9000` on the given serial."""
    serial_args = ["-s", args.serial] if args.serial else []
    port = args.port
    rc, out, err = _run_adb(
        serial_args + ["forward", f"tcp:{port}", "tcp:9000"], timeout=10)
    if rc != 0:
        print(f"adb forward failed: {err.strip() or out.strip()}",
              file=sys.stderr)
        return 1
    print(f"forwarded localhost:{port} -> {args.serial or 'device'}:9000")
    return 0


def cmd_wait_until_alive(args: argparse.Namespace) -> int:
    device = QaLabDevice(args.host, args.port, timeout_s=2.0)
    deadline = time.monotonic() + args.timeout
    while time.monotonic() < deadline:
        if device.alive(timeout_s=1.0):
            print(f"qalos at {args.host}:{args.port} is alive")
            return 0
        time.sleep(args.interval)
    print(f"qalos at {args.host}:{args.port} not alive after {args.timeout}s",
          file=sys.stderr)
    return 1


# ----------------------------------------------------------------------
# Argparse
# ----------------------------------------------------------------------


def _common_parser() -> argparse.ArgumentParser:
    p = argparse.ArgumentParser(add_help=False)
    p.add_argument("--host", default="localhost",
                   help="host running the qalos service (default: localhost)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT,
                   help="port the qalos service is on (default: 9000)")
    p.add_argument("--timeout", type=float, default=10.0,
                   help="HTTP timeout in seconds (default: 10)")
    p.add_argument("--display", type=int, default=0,
                   help="display ID for multi-display devices (default: 0)")
    return p


def _build_parser() -> argparse.ArgumentParser:
    parser = argparse.ArgumentParser(
        prog="qalos",
        description="Command-line client for the qalos RemoteControlService.")
    sub = parser.add_subparsers(dest="cmd", required=True)

    p = sub.add_parser("status", parents=[_common_parser()],
                       help="print /capabilities and /info for the target device")
    p.set_defaults(func=cmd_status)

    p = sub.add_parser("info", parents=[_common_parser()],
                       help="print /info (device metadata) for the target device")
    p.set_defaults(func=cmd_info)

    p = sub.add_parser("devices", help="discover reachable qalos services via adb")
    p.add_argument("--port-range", type=int, nargs=2, default=[9000, 9010],
                   metavar=("LO", "HI"),
                   help="port range to probe (default: 9000 9010)")
    p.set_defaults(func=cmd_devices)

    p = sub.add_parser("tap", parents=[_common_parser()], help="tap at (x, y)")
    p.add_argument("x", type=int)
    p.add_argument("y", type=int)
    p.set_defaults(func=cmd_tap)

    p = sub.add_parser("long-press", parents=[_common_parser()],
                       help="press and hold (x, y) for N ms")
    p.add_argument("x", type=int)
    p.add_argument("y", type=int)
    p.add_argument("duration_ms", type=int)
    p.set_defaults(func=cmd_long_press)

    p = sub.add_parser("swipe", parents=[_common_parser()],
                       help="linear drag from (x1, y1) to (x2, y2)")
    p.add_argument("x1", type=int)
    p.add_argument("y1", type=int)
    p.add_argument("x2", type=int)
    p.add_argument("y2", type=int)
    p.add_argument("--steps", type=int, default=20)
    p.add_argument("--duration-ms", type=int, default=300)
    p.set_defaults(func=cmd_swipe)

    p = sub.add_parser("pinch", parents=[_common_parser()],
                       help="two-finger zoom centered at (cx, cy)")
    p.add_argument("cx", type=int)
    p.add_argument("cy", type=int)
    p.add_argument("r1", type=int)
    p.add_argument("r2", type=int)
    p.add_argument("--steps", type=int, default=20)
    p.add_argument("--duration-ms", type=int, default=300)
    p.set_defaults(func=cmd_pinch)

    p = sub.add_parser("key", parents=[_common_parser()],
                       help="press (and release) a hardware key")
    p.add_argument("key_code", type=int,
                   help="Android KeyEvent.KEYCODE_* constant")
    p.add_argument("--no-release", action="store_true",
                   help="only send the down event (manual control)")
    p.set_defaults(func=cmd_key)

    p = sub.add_parser("type", parents=[_common_parser()],
                       help="type a string into the focused field")
    p.add_argument("text")
    p.set_defaults(func=cmd_type)

    p = sub.add_parser("launch", parents=[_common_parser()],
                       help="launch an app")
    p.add_argument("package")
    p.set_defaults(func=cmd_launch)

    p = sub.add_parser("force-stop", parents=[_common_parser()],
                       help="force-stop an app")
    p.add_argument("package")
    p.set_defaults(func=cmd_force_stop)

    p = sub.add_parser("screenshot", parents=[_common_parser()],
                       help="capture a screenshot and save to a file")
    p.add_argument("out_path", help="path to save the PNG to")
    p.add_argument("--width", type=int, default=0,
                   help="capture width (0 = native)")
    p.add_argument("--height", type=int, default=0,
                   help="capture height (0 = native)")
    p.add_argument("--quality", type=int, default=85,
                   help="PNG compression level 1-100 (default: 85)")
    p.set_defaults(func=cmd_screenshot)

    p = sub.add_parser("forward", help="set up `adb forward tcp:N tcp:9000`")
    p.add_argument("--serial", help="adb device serial (default: only device)")
    p.add_argument("--port", type=int, default=DEFAULT_PORT,
                   help="local port to forward to (default: 9000)")
    p.set_defaults(func=cmd_forward)

    p = sub.add_parser("wait-until-alive",
                       parents=[argparse.ArgumentParser(add_help=False)],
                       help="poll /health until 200 or timeout")
    p.add_argument("--host", default="localhost")
    p.add_argument("--port", type=int, default=DEFAULT_PORT)
    p.add_argument("--timeout", type=float, default=60.0,
                   help="max seconds to wait (default: 60)")
    p.add_argument("--interval", type=float, default=1.0,
                   help="poll interval seconds (default: 1.0)")
    p.set_defaults(func=cmd_wait_until_alive)

    return parser


def main(argv: Optional[List[str]] = None) -> int:
    parser = _build_parser()
    args = parser.parse_args(argv)
    try:
        return args.func(args)
    except QaLabError as e:
        print(f"qalos error: {e}", file=sys.stderr)
        return 1
    except KeyboardInterrupt:
        print("interrupted", file=sys.stderr)
        return 130


if __name__ == "__main__":
    sys.exit(main())
