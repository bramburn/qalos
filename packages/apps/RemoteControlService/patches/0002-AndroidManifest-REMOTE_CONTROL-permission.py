#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0002: declare the REMOTE_CONTROL signature permission.

Run as part of `tools/apply-qalos.sh`. Edits the upstream AOSP
framework AndroidManifest.xml in place. Fails loudly if the closing
</manifest> tag is not found.

Honors `QALOS_PATCH_CHECK=1`: in check mode, only verify that the
anchor would be found (or the patch already applied). Do not write
to the target file. Exits 0 if the patch would apply cleanly, 1 if
the anchor is missing.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/core/res/AndroidManifest.xml")

INSERT_BEFORE = "</manifest>"

IDEMPOTENCY_MARKER = "android.permission.REMOTE_CONTROL"

NEW_BLOCK = (
    "    <!-- qalos: signature permission that gates RemoteControlService. -->\n"
    '    <permission android:name="android.permission.REMOTE_CONTROL"\n'
    '        android:label="@string/permlab_remoteControl"\n'
    '        android:description="@string/permdesc_remoteControl"\n'
    '        android:protectionLevel="signature"\n'
    # AOSP-15 metalava requires new framework APIs to carry @FlaggedApi.
    # We don't define an aconfig flag for this vendor permission; suppress
    # the UnflaggedApi lint with tools:ignore. (If/when we ship an aconfig
    # flag for QaLab, drop the ignore and reference the flag here.)
    '        tools:ignore="UnflaggedApi" />\n'
)


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0002] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if IDEMPOTENCY_MARKER in text:
        if check_only:
            print(f"[0002] OK (already applied; check mode)")
        else:
            print(f"[0002] already applied (idempotent skip)")
        return 0
    if INSERT_BEFORE not in text:
        print(
            f"[0002] anchor </manifest> not found in {target}. "
            f"AOSP may have restructured the file. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    if check_only:
        print(f"[0002] OK (anchor found; check mode)")
        return 0
    new_text = text.replace(INSERT_BEFORE, NEW_BLOCK + INSERT_BEFORE, 1)
    target.write_text(new_text, encoding="utf-8")
    print(f"[0002] inserted REMOTE_CONTROL permission block")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
