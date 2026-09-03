#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0003: add the human-readable labels for the REMOTE_CONTROL permission.

Run as part of `tools/apply-qalos.sh`. Edits
frameworks/base/core/res/res/values/strings.xml in place.
"""

from __future__ import annotations

import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/core/res/res/values/strings.xml")

INSERT_BEFORE = "</resources>"

NEW_BLOCK = (
    "    <!-- qalos: human-readable labels for the REMOTE_CONTROL permission. -->\n"
    '    <string name="permlab_remoteControl">Remote control (qalos)</string>\n'
    '    <string name="permdesc_remoteControl">Allows a system-signed app to drive input, screenshot, and app lifecycle for QA tests.</string>\n'
)


def main(work_tree: Path) -> int:
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0003] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if "permlab_remoteControl" in text:
        print(f"[0003] already applied (idempotent skip)")
        return 0
    if INSERT_BEFORE not in text:
        print(
            f"[0003] anchor </resources> not found in {target}. "
            f"AOSP may have moved the strings layout. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    new_text = text.replace(INSERT_BEFORE, NEW_BLOCK + INSERT_BEFORE, 1)
    target.write_text(new_text, encoding="utf-8")
    print(f"[0003] inserted REMOTE_CONTROL permission labels")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
