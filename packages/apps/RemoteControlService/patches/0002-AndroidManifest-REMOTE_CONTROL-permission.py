#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0002: declare the REMOTE_CONTROL signature permission.

Run as part of `tools/apply-qalos.sh`. Edits the upstream AOSP
framework AndroidManifest.xml in place. Fails loudly if the closing
</manifest> tag is not found.
"""

from __future__ import annotations

import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/core/res/AndroidManifest.xml")

INSERT_BEFORE = "</manifest>"

NEW_BLOCK = (
    "    <!-- qalos: signature permission that gates RemoteControlService. -->\n"
    '    <permission android:name="android.permission.REMOTE_CONTROL"\n'
    '        android:label="@string/permlab_remoteControl"\n'
    '        android:description="@string/permdesc_remoteControl"\n'
    '        android:protectionLevel="signature" />\n'
)


def main(work_tree: Path) -> int:
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0002] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if "android.permission.REMOTE_CONTROL" in text:
        print(f"[0002] already applied (idempotent skip)")
        return 0
    if INSERT_BEFORE not in text:
        print(
            f"[0002] anchor </manifest> not found in {target}. "
            f"AOSP may have restructured the file. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    new_text = text.replace(INSERT_BEFORE, NEW_BLOCK + INSERT_BEFORE, 1)
    target.write_text(new_text, encoding="utf-8")
    print(f"[0002] inserted REMOTE_CONTROL permission block")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
