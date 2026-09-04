#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0004: register the qalos RemoteControlService in SystemServer.

Run as part of `tools/apply-qalos.sh`. Edits
frameworks/base/services/java/com/android/server/SystemServer.java in
place in two places:

  1. Add `import com.qalos.remotectl.RemoteControlService;` to the
     import block (alphabetically adjacent to the existing
     `com.android.server.input.InputManagerService` import).
  2. Insert the service start block immediately after the
     `traceEnd` that closes the InputManager start block.

AOSP 15 pattern (verified against android-15.0.0_r1):

    t.traceBegin("StartInputManagerService");
    inputManager = new InputManagerService(context);
    t.traceEnd();

Note the `t.` prefix on both `traceBegin` and `traceEnd`. The static
`traceBeginAndSlog` method that AOSP 14 used was removed in AOSP 15;
the modern pattern is a local `Trace t` instance.

The import line is required: `mSystemServiceManager.startService(
RemoteControlService.class)` references a class literal and will
fail to compile with "cannot find symbol: class RemoteControlService"
without the import. The previous version of this patch missed the
import and would have produced a build that compiles the file
shape but fails to link the class.

Honors `QALOS_PATCH_CHECK=1`: in check mode, only verify that the
anchors would be found (or the patch already applied). Do not write
to the target file.
"""

from __future__ import annotations

import os
import re
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/services/java/com/android/server/SystemServer.java")

# Idempotency marker: this string appears only when the import has
# been added AND the service-start block has been added. The two
# edits use the same marker so a partial application (import only,
# or service-start only) cannot happen.
IDEMPOTENCY_MARKER = "StartRemoteControlService"

# (1) Import insertion. Anchor on the line just after the existing
# `com.android.server.input.InputManagerService` import. The
# `com.android.server.input` block is alphabetically adjacent to
# `com.android.server.q...` in AOSP 15, so inserting right after
# `InputManagerService` keeps the alphabetical ordering the rest
# of the import block follows.
IMPORT_INSERT_AFTER = "import com.android.server.input.InputManagerService;\n"
IMPORT_INSERT_BEFORE_TEXT = IMPORT_INSERT_AFTER + (
    "import com.qalos.remotectl.RemoteControlService;\n"
)

# (2) Service-start block. Match the InputManagerService construction
# + the traceEnd that closes its start block. The pattern is
# permissive about the variable name on the LHS (AOSP 15 calls it
# `inputManager`; the next release may rename) and the surrounding
# whitespace.
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
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0004] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if IDEMPOTENCY_MARKER in text:
        if check_only:
            print("[0004] OK (already applied; check mode)")
        else:
            print("[0004] already applied (idempotent skip)")
        return 0
    if not PATTERN.search(text):
        print(
            f"[0004] anchor (InputManagerService start + t.traceEnd) not found in {target}. "
            f"AOSP may have refactored SystemServer. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    if check_only:
        # Check mode: only verify the import anchor too.
        if IMPORT_INSERT_AFTER not in text:
            print(
                f"[0004] import anchor ({IMPORT_INSERT_AFTER.strip()}) not found in {target}. "
                f"AOSP may have refactored the imports block. See REBASE.md.",
                file=sys.stderr,
            )
            return 1
        print("[0004] OK (anchor regex + import anchor both match; check mode)")
        return 0
    # Apply both edits. Order matters: do the import first, then
    # the service-start block. The service-start regex matches the
    # un-edited text, so applying it first then the import would
    # also work, but doing the import first keeps the diff readable
    # if a partial apply is ever inspected.
    if IMPORT_INSERT_AFTER not in text:
        print(
            f"[0004] import anchor ({IMPORT_INSERT_AFTER.strip()}) not found in {target}. "
            f"AOSP may have refactored the imports block. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    text = text.replace(IMPORT_INSERT_AFTER, IMPORT_INSERT_BEFORE_TEXT, 1)
    new_text, n = PATTERN.subn(lambda m: m.group(1) + NEW_BLOCK, text, count=1)
    if n == 0:
        # Should not happen given the PATTERN.search above, but be
        # defensive.
        print(
            f"[0004] anchor matched on search but not on subn — file changed between read and write?",
            file=sys.stderr,
        )
        return 1
    target.write_text(new_text, encoding="utf-8")
    print("[0004] registered RemoteControlService in SystemServer (import + start block)")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
