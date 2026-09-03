#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0001: add `com.qalos.remotectl` to the services.core java_library srcs.

Run as part of `tools/apply-qalos.sh`. The script edits the upstream
AOSP file in place. Fails loudly if the anchor is not found — that
means the AOSP revision has refactored the file and the patch needs
to be rebased (see REBASE.md).
"""

from __future__ import annotations

import re
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/services/core/Android.bp")

NEW_LINE = '        "java/com/qalos/remotectl/*.java",\n'

# Match the services.core java_library and its srcs block. The
# pattern is conservative: `name: "services.core"` followed by an
# `srcs: [` somewhere on a subsequent line.
PATTERN = re.compile(
    r'(java_library\s*\{\s*name:\s*"services\.core",\s*'
    r'srcs:\s*\[\s*\n)',
    re.MULTILINE,
)


def main(work_tree: Path) -> int:
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0001] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if NEW_LINE in text:
        print(f"[0001] already applied (idempotent skip)")
        return 0
    new_text, n = PATTERN.subn(lambda m: m.group(1) + NEW_LINE, text, count=1)
    if n == 0:
        print(
            f"[0001] anchor not found in {target}. "
            f"AOSP may have refactored services.core/Android.bp. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    target.write_text(new_text, encoding="utf-8")
    print(f"[0001] inserted {NEW_LINE.strip()} into services.core srcs")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
