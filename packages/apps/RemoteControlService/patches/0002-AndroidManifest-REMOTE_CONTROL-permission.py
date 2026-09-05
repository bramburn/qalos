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

# Anchor for adding the `xmlns:tools` namespace to the root <manifest>
# element. The root element on AOSP 15 reads:
#   <manifest xmlns:android="http://schemas.android.com/apk/res/android"
#             package="android" coreApp="true" ...>
# The `tools:` prefix used in `tools:ignore="UnflaggedApi"` (see NEW_BLOCK
# below) MUST be declared on the root or the build dies with
#   error: unbound prefix: line 9003, column 4
# at the `framework-res` manifest_fixer step. We add the namespace once
# and idempotently.
ROOT_ELEMENT_LINE = '<manifest xmlns:android="http://schemas.android.com/apk/res/android"'

ROOT_ELEMENT_LINE_PATCHED = (
    '<manifest xmlns:android="http://schemas.android.com/apk/res/android"\n'
    '          xmlns:tools="http://schemas.android.com/tools"'
)

NAMESPACE_MARKER = 'xmlns:tools="http://schemas.android.com/tools"'

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

    # Step 1: ensure the root <manifest> declares the `tools` namespace.
    # Idempotent via NAMESPACE_MARKER; safe to run even if already applied.
    if NAMESPACE_MARKER not in text:
        if ROOT_ELEMENT_LINE not in text:
            print(
                f"[0002] root <manifest> line not found in {target}. "
                f"AOSP may have restructured the file. See REBASE.md.",
                file=sys.stderr,
            )
            return 1
        text = text.replace(ROOT_ELEMENT_LINE, ROOT_ELEMENT_LINE_PATCHED, 1)
        if not check_only:
            target.write_text(text, encoding="utf-8")
            print(f"[0002] added xmlns:tools namespace to root <manifest>")
        else:
            print(f"[0002] OK (root namespace anchor found; check mode)")

    # Step 2: insert the REMOTE_CONTROL permission block (idempotent).
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
