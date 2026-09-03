#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0004: register the qalos RemoteControlService in SystemServer.

Run as part of `tools/apply-qalos.sh`. Edits
frameworks/base/services/java/com/android/server/SystemServer.java in
place, immediately after the traceEnd that closes the InputManager
start block.
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/services/java/com/android/server/SystemServer.java")

# Match the InputManagerService construction + the traceEnd that
# closes its start block. The pattern is permissive: the
# InputManagerService line may be `inputManager = new InputManagerService(...)`
# or `InputManagerService inputManager = new InputManagerService(...)`.
# We anchor on the `new InputManagerService(` token and the
# `traceEnd();` call two lines down.
PATTERN = re.compile(
    r'((?:\s*InputManagerService\s+\w+\s*=\s*new\s+InputManagerService\([^)]*\);'
    r'|\s*\w+\s*=\s*new\s+InputManagerService\([^)]*\);)\n'
    r'\s*traceEnd\(\);\n)',
    re.MULTILINE,
)

NEW_BLOCK = (
    "        traceBeginAndSlog(\"StartRemoteControlService\");\n"
    "        mSystemServiceManager.startService(RemoteControlService.class);\n"
    "        traceEnd();\n"
)


def main(work_tree: Path) -> int:
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0004] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if "StartRemoteControlService" in text:
        print(f"[0004] already applied (idempotent skip)")
        return 0
    new_text, n = PATTERN.subn(lambda m: m.group(1) + NEW_BLOCK, text, count=1)
    if n == 0:
        print(
            f"[0004] anchor (InputManagerService start + traceEnd) not found in {target}. "
            f"AOSP may have refactored SystemServer. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    target.write_text(new_text, encoding="utf-8")
    print(f"[0004] registered RemoteControlService in SystemServer")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv > 1) else Path.cwd()
    sys.exit(main(work_tree))
