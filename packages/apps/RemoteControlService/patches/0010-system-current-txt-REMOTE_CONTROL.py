#!/usr/bin/env python3
"""
qalos patch 0010 — add REMOTE_CONTROL permission to system-current.txt.

Patch 0002 declares the qalos REMOTE_CONTROL signature-protected permission
in frameworks/base/core/res/AndroidManifest.xml. Patch 0005 annotates it
with @hide @SystemApi. The AOSP build system runs metalava to generate
system API stubs from the source tree; the generated stub includes the new
REMOTE_CONTROL permission. The checkapi step then diffs the generated stub
against the baseline frameworks/base/core/api/system-current.txt and FAILS
because current.txt doesn't list REMOTE_CONTROL yet.

Fix: add the missing line to current.txt at its alphabetically-correct
position (between REGISTER_STATS_PULL_ATOM and REMOTE_DISPLAY_PROVIDER).

Why this can't be done via the "regenerate current.txt" target:
The target `m system-api-stubs-docs-non-updatable-update-current-api` works
on a fresh AOSP build, but it requires running the full metalava + stub
generation phase first. Since qalos builds only a subset (we don't ship
most AOSP framework jars), we just add the line by hand.

Idempotent: only adds the line if it's missing.
"""

import sys
from pathlib import Path

WORK_TREE = Path(sys.argv[1])
CURRENT = WORK_TREE / "frameworks/base/core/api/system-current.txt"
LINE = '    field public static final String REMOTE_CONTROL = "android.permission.REMOTE_CONTROL";'
ANCHOR_BEFORE = '    field public static final String REMOTE_DISPLAY_PROVIDER'

def main() -> int:
    if not CURRENT.exists():
        print(f"patch 0010: SKIP (file not found): {CURRENT}", file=sys.stderr)
        return 0
    text = CURRENT.read_text(encoding="utf-8")
    if LINE in text:
        print("patch 0010: OK (REMOTE_CONTROL already in current.txt)")
        return 0
    if ANCHOR_BEFORE not in text:
        print(f"patch 0010: FAILED (anchor not found: {ANCHOR_BEFORE!r})", file=sys.stderr)
        return 1
    new_text = text.replace(ANCHOR_BEFORE, LINE + "\n" + ANCHOR_BEFORE, 1)
    CURRENT.write_text(new_text, encoding="utf-8")
    print("patch 0010: added REMOTE_CONTROL to system-current.txt")
    return 0

if __name__ == "__main__":
    sys.exit(main())
