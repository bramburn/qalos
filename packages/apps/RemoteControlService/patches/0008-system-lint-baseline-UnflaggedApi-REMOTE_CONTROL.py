#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0008: suppress the UnflaggedApi lint error for REMOTE_CONTROL.

AOSP 15 metalava requires every NEW permission (declared in
AndroidManifest.xml and emitted in the generated system stubs) to be
marked `@FlaggedApi` with a corresponding `.aconfig` declaration. The
qalos REMOTE_CONTROL permission intentionally does NOT use @FlaggedApi —
the qalos flag in `services.core/aconfig/qalos.aconfig` is unreachable
from framework-res' aapt2 build (the dependency chain doesn't include
`services.core`). See REBASE.md and the doc comment on patch 0005.

The cleanest workaround: add a baseline entry to
`frameworks/base/core/api/system-lint-baseline.txt` so metalava accepts
this specific new API without the @FlaggedApi flag. This is the same
trick AOSP itself uses for several other signature-only permissions
(ACCESS_SMARTSPACE, ALWAYS_UPDATE_WALLPAPER, CAMERA_HEADLESS_SYSTEM_USER,
KEYPHRASE_ENROLLMENT_APPLICATION, LAUNCH_PERMISSION_SETTINGS,
MANAGE_VOICE_KEYPHRASES, READ_INSTALLED_SESSION_PATHS,
REGISTER_NSD_OFFLOAD_ENGINE, REPORT_USAGE_STATS — see lines 1918+ of
system-lint-baseline.txt in a clean AOSP-15 tree).

This patch idempotently inserts (or no-ops if present) the following
two lines into system-lint-baseline.txt, immediately after the
existing `UnflaggedApi: ...REGISTER_NSD_OFFLOAD_ENGINE:` block to keep
the alphabetical ordering of permission suppressions:

    UnflaggedApi: android.Manifest.permission#REMOTE_CONTROL:
        New API must be flagged with @FlaggedApi: field android.Manifest.permission.REMOTE_CONTROL

Insertion strategy: append directly after the existing REMOTE_* /
REGISTER_* suppression block, so the alphabetical ordering is preserved.
If the anchor line is not found, fall back to appending before the
final line of the file (the baseline format is line-oriented; blank
lines between groups are tolerated).

Honors `QALOS_PATCH_CHECK=1` for dry-run pre-flight.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/core/api/system-lint-baseline.txt")

# The two-line suppression entry, separated by a blank line from the
# preceding block to match the file's formatting.
ENTRY = (
    "UnflaggedApi: android.Manifest.permission#REMOTE_CONTROL:\n"
    "    New API must be flagged with @FlaggedApi: field "
    "android.Manifest.permission.REMOTE_CONTROL\n"
)

# Anchor: insert AFTER this line (REGISTER_NSD_OFFLOAD_ENGINE is
# alphabetically just before REMOTE_CONTROL).
ANCHOR = "UnflaggedApi: android.Manifest.permission#REGISTER_NSD_OFFLOAD_ENGINE:"


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0008] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if "UnflaggedApi: android.Manifest.permission#REMOTE_CONTROL:" in text:
        if check_only:
            print("[0008] OK (already applied; check mode)")
        else:
            print("[0008] already applied (idempotent skip)")
        return 0
    if ANCHOR not in text:
        # Fallback: append at end of file.
        if check_only:
            print(
                "[0008] OK (anchor not found; would append at end; check mode)"
            )
        else:
            sep = "" if text.endswith("\n") else "\n"
            new_text = text + sep + ENTRY
            target.write_text(new_text, encoding="utf-8")
            print(
                "[0008] appended REMOTE_CONTROL UnflaggedApi suppression "
                "(anchor not found, used end-of-file fallback)"
            )
        return 0
    if check_only:
        print("[0008] OK (anchor found; check mode)")
        return 0
    # Insert ENTRY (with a blank line before it to match file formatting)
    # immediately after the ANCHOR's full block (the anchor line plus
    # its indented detail line, plus the trailing blank line that
    # separates blocks in the baseline file).
    anchor_idx = text.index(ANCHOR)
    # Find end of the anchor block: the next blank line.
    block_end = text.find("\n\n", anchor_idx)
    if block_end == -1:
        # No following blank line; just append ENTRY + \n\n.
        insertion = "\n" + ENTRY + "\n"
        insert_at = anchor_idx + len(ANCHOR)
    else:
        insertion = ENTRY + "\n"
        insert_at = block_end  # insert BEFORE the blank line
    new_text = text[:insert_at] + insertion + text[insert_at:]
    target.write_text(new_text, encoding="utf-8")
    print(
        "[0008] inserted REMOTE_CONTROL UnflaggedApi suppression after "
        "REGISTER_NSD_OFFLOAD_ENGINE block"
    )
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
