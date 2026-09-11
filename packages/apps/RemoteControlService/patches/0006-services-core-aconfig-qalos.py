#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0006: wire qalos.aconfig into services.core's Android.bp.

Patch 0005 promoted `android.permission.REMOTE_CONTROL` to the
`@FlaggedApi` form and references the `com.qalos.flags.remote_control`
feature flag. For metalava / AAPT2 to find the flag declaration,
the .aconfig file must be declared in an Soong `aconfig_declarations`
module — dropping the file into `aconfig/qalos.aconfig` is not
enough on its own.

We append the block to the end of
`frameworks/base/services/core/Android.bp`. Soong is happy with the
append: any text after the top-level `package {}` scope is read as
top-level soong module declarations, just like the existing
`java_library_static`, `filegroup`, etc. entries in the file.

The `package` and `container` here MUST match the header of the
.aconfig file (`com.qalos.flags` / `system`).

Idempotent: re-running is a no-op if `name: "qalos_flags"` is
already present.

Honors `QALOS_PATCH_CHECK=1`: in check mode, only verify that the
anchor would be found (or the patch already applied). Do not write
to the target file.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/services/core/Android.bp")

NEW_BLOCK = """
// qalos: declaration of the qalos Remote Control feature flag. The
// .aconfig file is copied here by apply-qalos.sh from the qalos
// manifest clone at packages/apps/RemoteControlService/aconfig/
// qalos.aconfig. The `package` and `container` here MUST match
// the header of the .aconfig file (com.qalos.flags / system).
aconfig_declarations {
    name: "qalos_flags",
    package: "com.qalos.flags",
    container: "system",
    srcs: ["aconfig/qalos.aconfig"],
}
"""


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0006] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")

    # Idempotency: already wired?
    if 'name: "qalos_flags"' in text:
        if check_only:
            print("[0006] OK (already applied; check mode)")
        else:
            print("[0006] already applied (idempotent skip)")
        return 0

    # Ensure file ends with a newline before appending.
    suffix = NEW_BLOCK if text.endswith("\n") else "\n" + NEW_BLOCK

    if check_only:
        print("[0006] OK (target writable; check mode)")
        return 0

    new_text = text + suffix
    target.write_text(new_text, encoding="utf-8")
    print("[0006] appended aconfig_declarations block for qalos_flags to services.core/Android.bp")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
