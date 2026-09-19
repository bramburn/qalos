#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0006: wire qalos.aconfig into services.core's Android.bp.

This patch appends an `aconfig_declarations` block for the qalos aconfig
flags to `frameworks/base/services/core/Android.bp`. The block is
copied verbatim from the qalos.aconfig header.

CURRENT STATUS (2026-09-19): orphaned. Patch 0005 originally promoted
the REMOTE_CONTROL permission with `@FlaggedApi` and referenced the
`com.qalos.flags.remote_control` flag declared here. Commit `9d98413`
("drop @FlaggedApi on REMOTE_CONTROL") replaced that annotation with
`@SystemApi @hide`, leaving no consumer of the flag. The block is kept
appended so that any future aconfig consumer in services.core resolves
without re-running this patch; it is otherwise dead code.

Idempotent: re-running is a no-op if `name: "qalos_flags"` is already
present. Honors `QALOS_PATCH_CHECK=1`: in check mode, only verify the
target would be writable; do not write.
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
