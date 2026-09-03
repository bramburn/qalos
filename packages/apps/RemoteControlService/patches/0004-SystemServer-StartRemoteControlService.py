#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0004: register the qalos RemoteControlService in SystemServer.

Run as part of `tools/apply-qalos.sh`. Edits
frameworks/base/services/java/com/android/server/SystemServer.java in
place, immediately after the traceEnd that closes the InputManager
start block.

AOSP 15 pattern (verified against android-15.0.0_r1):

    t.traceBegin("StartInputManagerService");
    inputManager = new InputManagerService(context);
    t.traceEnd();

Note the `t.` prefix on both `traceBegin` and `traceEnd`. The static
`traceBeginAndSlog` method that AOSP 14 used was removed in AOSP 15;
the modern pattern is a local `Trace t` instance.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/services/java/com/android/server/SystemServer.java")

# Match the InputManagerService construction + the traceEnd that
# closes its start block. The pattern is permissive about the
# variable name on the LHS (AOSP 15 calls it `inputManager`; the
# next release may rename) and the surrounding whitespace.
PATTERN = re.compile(
    r'((?:\s*\w+\s*=\s*new\s+InputManagerService\([^)]*\);)\n'
    r'\s*t\.traceEnd\(\);\n)',
    re.MULTILINE,
)

NEW_BLOCK = (
    "            t.traceBegin(\"StartRemoteControlService\");\n"
    "            mSystemServiceManager.startService(RemoteControlService.class);\n"
    "            t.traceEnd();\n"
)


def main(work_tree: Path) -> int:
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0004] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if "StartRemoteControlService" in text:
        print("[0004] already applied (idempotent skip)")
        return 0
    new_text, n = PATTERN.subn(lambda m: m.group(1) + NEW_BLOCK, text, count=1)
    if n == 0:
        print(
            f"[0004] anchor (InputManagerService start + t.traceEnd) not found in {target}. "
            f"AOSP may have refactored SystemServer. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    target.write_text(new_text, encoding="utf-8")
    print("[0004] registered RemoteControlService in SystemServer")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
