#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0005: document REMOTE_CONTROL as @SystemApi @hide.

AOSP 15's metalava rejects a new signature `<permission>` that is not
either (a) listed in `frameworks/base/core/api/current.txt`, or (b)
marked `@FlaggedApi` with a corresponding `.aconfig` declaration.

We tried (b) first (the original version of this patch added the
`@FlaggedApi("com.qalos.flags.remote_control")` annotation AND the
`android:featureFlag="com.qalos.flags.remote_control"` attribute).
The annotation was accepted by metalava, but aapt2 — which compiles
`framework-res` — complained:

    error: attribute 'android:featureFlag' has flag
    'com.qalos.flags.remote_control' not found in flags from
    --feature_flags parameter.

aapt2's `--feature_flags` list is populated from the `aconfig_declarations`
blocks that appear as transitive dependencies of `framework-res`. The
qalos flag is declared in `services.core/aconfig/qalos.aconfig`, but
`services.core` is not in the `framework-res` dependency graph, so
the flag never reaches aapt2.

The fix we settled on: keep the permission signature-protected
(security model unchanged) but DON'T gate it with a feature flag.
The permission is always active. Runtime gating can be added later
by moving the aconfig to a package that's in the framework-res
dependency graph (a qalos.flags-aconfig library, declared in
frameworks/base/core/res/Android.bp's `flags_packages` list).

This patch now ONLY adds the `@SystemApi @hide` markers (which metalava
needs) and does NOT add `@FlaggedApi` or `android:featureFlag`. The
permission is signature-protected (so callers need the qalos platform
key to hold it), but is always present in the API surface.

    <!-- @SystemApi @hide
         qalos: signature permission that gates RemoteControlService. -->
    <permission android:name="android.permission.REMOTE_CONTROL"
        android:label="@string/permlab_remoteControl"
        android:description="@string/permdesc_remoteControl"
        android:protectionLevel="signature" />

The permission must still be added to `frameworks/base/core/api/current.txt`
so checkapi accepts it. Patch 0007 (separate file) handles that.

Idempotent: re-running is a no-op if the @SystemApi @hide markers are
already present. Honors `QALOS_PATCH_CHECK=1` for dry-run pre-flight.
"""

from __future__ import annotations

import os
import re
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
    "    <!-- @SystemApi @hide\n"
    "         qalos: signature permission that gates RemoteControlService. -->\n"
    '    <permission android:name="android.permission.REMOTE_CONTROL"\n'
    '        android:label="@string/permlab_remoteControl"\n'
    '        android:description="@string/permdesc_remoteControl"\n'
    '        android:protectionLevel="signature" />\n'
)


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0005] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    # Idempotency: @SystemApi @hide markers already present?
    if "@SystemApi @hide" in text and "REMOTE_CONTROL" in text:
        # Verify the REMOTE_CONTROL block specifically has the markers.
        m = re.search(
            r"<!-- @SystemApi @hide[\s\S]*?REMOTE_CONTROL[\s\S]*?/>", text
        )
        if m:
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
    print("[0005] annotated REMOTE_CONTROL as @SystemApi @hide (no feature flag)")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
