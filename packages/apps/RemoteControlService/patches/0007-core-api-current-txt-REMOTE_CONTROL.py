#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0007: add REMOTE_CONTROL to frameworks/base/core/api/current.txt.

Patch 0005 downgraded the permission from `@FlaggedApi` back to plain
`@SystemApi @hide` to avoid the aapt2 feature-flag issue (the qalos
aconfig is in services.core which isn't in framework-res' dep graph,
so aapt2's --feature_flags list never sees the flag).

Without @FlaggedApi, metalava/checkapi requires the permission to be
listed in `frameworks/base/core/api/current.txt` explicitly. This patch
inserts the corresponding line.

The insertion point is alphabetical: between REMOTE_AUDIO and
REMOVE_TASKS in the android.permission class.

Idempotent: re-running is a no-op if `REMOTE_CONTROL = "android.permission.REMOTE_CONTROL"`
is already present.

Honors `QALOS_PATCH_CHECK=1` for dry-run pre-flight.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/core/api/current.txt")

NEW_LINE = (
    '    field public static final String REMOTE_CONTROL = '
    '"android.permission.REMOTE_CONTROL";\n'
)

# Insert AFTER this anchor line (RECORD_AUDIO is alphabetically right
# before REMOTE_CONTROL). Falls back to before the closing brace of the
# android.permission class if the anchor isn't found.
ANCHOR = 'RECORD_AUDIO = "android.permission.RECORD_AUDIO";'


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0007] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if 'REMOTE_CONTROL = "android.permission.REMOTE_CONTROL"' in text:
        if check_only:
            print("[0007] OK (already applied; check mode)")
        else:
            print("[0007] already applied (idempotent skip)")
        return 0
    if ANCHOR not in text:
        nearby = [l for l in text.splitlines() if "RECORD" in l or "REMOTE" in l]
        print(
            f"[0007] anchor '{ANCHOR}' not found in {target}. "
            f"Nearby lines: {nearby[:5]}. Cannot determine insertion point. "
            "See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    if check_only:
        print("[0007] OK (anchor found; check mode)")
        return 0
    new_text = text.replace(ANCHOR, ANCHOR + "\n" + NEW_LINE.rstrip("\n"), 1)
    target.write_text(new_text, encoding="utf-8")
    print("[0007] added REMOTE_CONTROL to core/api/current.txt")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
