#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0005: gate the REMOTE_CONTROL permission with @FlaggedApi.

AOSP 15's metalava rejects a new signature `<permission>` that is not
either (a) listed in `frameworks/base/core/api/current.txt`, or (b)
marked `@FlaggedApi` with a corresponding `.aconfig` declaration.
Patch 0002 inserts the permission without the flag annotation, which
fails checkapi. This patch (0005) upgrades the permission XML to the
canonical AOSP 15 form:

    <!-- @SystemApi @FlaggedApi("com.qalos.flags.remote_control") @hide
         qalos: signature permission that gates RemoteControlService. -->
    <permission android:name="android.permission.REMOTE_CONTROL"
        android:label="@string/permlab_remoteControl"
        android:description="@string/permdesc_remoteControl"
        android:protectionLevel="signature"
        android:featureFlag="com.qalos.flags.remote_control" />

The flag itself is declared in
`packages/apps/RemoteControlService/aconfig/qalos.aconfig`, which
`apply-qalos.sh` copies to
`frameworks/base/services/core/aconfig/qalos.aconfig` before this patch
runs (see `apply-qalos.sh` `copy_path` step).

Run as part of `tools/apply-qalos.sh`. Edits the upstream AOSP
framework AndroidManifest.xml in place. Idempotent: re-running is a
no-op if the `android:featureFlag` attribute is already present.

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

OLD_BLOCK = (
    "    <!-- qalos: signature permission that gates RemoteControlService. -->\n"
    '    <permission android:name="android.permission.REMOTE_CONTROL"\n'
    '        android:label="@string/permlab_remoteControl"\n'
    '        android:description="@string/permdesc_remoteControl"\n'
    '        android:protectionLevel="signature" />\n'
)

NEW_BLOCK = (
    '    <!-- @SystemApi @FlaggedApi("com.qalos.flags.remote_control") @hide\n'
    "         qalos: signature permission that gates RemoteControlService. -->\n"
    '    <permission android:name="android.permission.REMOTE_CONTROL"\n'
    '        android:label="@string/permlab_remoteControl"\n'
    '        android:description="@string/permdesc_remoteControl"\n'
    '        android:protectionLevel="signature"\n'
    '        android:featureFlag="com.qalos.flags.remote_control" />\n'
)


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0005] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    # Idempotency: already upgraded (featureFlag attribute present)?
    if 'android:featureFlag="com.qalos.flags.remote_control"' in text:
        if check_only:
            print("[0005] OK (already applied; check mode)")
        else:
            print("[0005] already applied (idempotent skip)")
        return 0
    if OLD_BLOCK not in text:
        print(
            "[0005] anchor not found: the REMOTE_CONTROL permission block "
            "(as inserted by patch 0002) was not located. Patch 0002 must "
            "have changed or been skipped. See REBASE.md.",
            file=sys.stderr,
        )
        return 1
    if check_only:
        print("[0005] OK (anchor found; check mode)")
        return 0
    new_text = text.replace(OLD_BLOCK, NEW_BLOCK, 1)
    target.write_text(new_text, encoding="utf-8")
    print("[0005] promoted REMOTE_CONTROL to @FlaggedApi (com.qalos.flags.remote_control)")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
