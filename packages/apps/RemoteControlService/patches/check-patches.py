#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Check that the four qalos patches would apply cleanly to the given
AOSP working tree. Exits 0 if all four apply, 1 otherwise.

Usage:
    python3 packages/apps/RemoteControlService/patches/check-patches.py [WORK_TREE]

WORK_TREE defaults to the current directory. Each patch script is
run in "check" mode by setting the env var QALOS_PATCH_CHECK=1; the
scripts are designed to support that mode and exit 0 on a clean
apply, 1 on a broken apply, and 0 on "already applied" (idempotent).
"""

from __future__ import annotations

import os
import subprocess
import sys
from pathlib import Path

PATCH_DIR = Path(__file__).resolve().parent

PATCHES = [
    "0002-AndroidManifest-REMOTE_CONTROL-permission.py",
    "0003-strings-REMOTE_CONTROL.py",
    "0004-SystemServer-StartRemoteControlService.py",
]


def main() -> int:
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    if not (work_tree / "frameworks/base/services/core/Android.bp").exists():
        print(f"work tree {work_tree} does not look like an AOSP checkout", file=sys.stderr)
        return 1

    failed = 0
    for name in PATCHES:
        patch = PATCH_DIR / name
        if not patch.exists():
            print(f"  MISSING: {name}")
            failed += 1
            continue
        env = os.environ.copy()
        env["QALOS_PATCH_CHECK"] = "1"
        result = subprocess.run(
            [sys.executable, str(patch), str(work_tree)],
            capture_output=True,
            text=True,
            env=env,
        )
        if result.returncode == 0:
            print(f"  OK     {name}")
        else:
            print(f"  FAIL   {name}: {result.stderr.strip() or result.stdout.strip()}")
            failed += 1

    if failed:
        print(
            f"\n{failed} of {len(PATCHES)} patch(es) would not apply cleanly.\n"
            f"See REBASE.md for the recovery procedure.",
            file=sys.stderr,
        )
        return 1
    print(f"\nAll {len(PATCHES)} patch(es) apply cleanly to {work_tree}.")
    return 0


if __name__ == "__main__":
    sys.exit(main())
