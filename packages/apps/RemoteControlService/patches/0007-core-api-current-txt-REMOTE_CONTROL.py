#!/usr/bin/env python3
# SPDX-License-Identifier: MIT
"""Apply patch 0007: REMOVE REMOTE_CONTROL from frameworks/base/core/api/current.txt.

History (qalos build attempts, see REBASE.md):

  Attempt 1 (commit 9d98413): the permission was `@FlaggedApi` with a feature
    flag in `services.core/aconfig/qalos.aconfig`. That failed aapt2 because
    `services.core` is not in the `framework-res` dep graph, so the flag
    never reached aapt2's --feature_flags list. We dropped `@FlaggedApi`.

  Attempts 2-3 (commit 34d0f9f): we kept the permission as plain
    `@SystemApi @hide` and added REMOTE_CONTROL to `current.txt` as a
    band-aid — metalava/checkapi accepted it because both the generated
    stub and current.txt had it. The preflight checkapi passed.

  Attempt 4-5 (Sept 12 2026): the full build's `check_current_api` ran on
    BOTH the public (`api-stubs-docs-non-updatable`) AND the system
    (`system-api-stubs-docs-non-updatable`) stubs. Both failed:

      - Public stub checkapi: REMOTE_CONTROL was in current.txt (we added
        it) but the generated PUBLIC stub did NOT have it (the permission
        is @hide, hidden from public). Diff mismatch → build failed.

      - System stub metalava: REMOTE_CONTROL WAS in the generated SYSTEM
        stub (because @SystemApi) but metalava's lint complained
        `New API must be flagged with @FlaggedApi` (UnflaggedApi error)
        because we dropped @FlaggedApi.

The correct model for a new @SystemApi @hide signature-only permission:
  - It belongs in the generated SYSTEM stub (because @SystemApi).
  - It does NOT belong in current.txt (because @hide hides it from
    public-facing API tracking).
  - It DOES trigger the `UnflaggedApi` lint unless suppressed (because
    it's a new API that lacks @FlaggedApi).

So:
  - current.txt addition (old patch 0007) was wrong → REMOVE it.
  - The `UnflaggedApi` lint needs to be suppressed in
    `frameworks/base/core/api/system-lint-baseline.txt` → handled by
    a new patch 0008.

This patch 0007 now idempotently REMOVES REMOTE_CONTROL from current.txt
(removes the line that the previous version of this script added). It
is a no-op if the line is already absent.

The line is identified by its full text (including leading whitespace and
trailing semicolon) so we don't accidentally remove a partial match.

Honors `QALOS_PATCH_CHECK=1` for dry-run pre-flight.
"""

from __future__ import annotations

import os
import sys
from pathlib import Path

TARGET_REL = Path("frameworks/base/core/api/current.txt")

# The exact line we want to remove. Includes 4-space indent + newline.
REMOVE_LINE = (
    '    field public static final String REMOTE_CONTROL = '
    '"android.permission.REMOTE_CONTROL";\n'
)


def main(work_tree: Path) -> int:
    check_only = os.environ.get("QALOS_PATCH_CHECK") == "1"
    target = work_tree / TARGET_REL
    if not target.exists():
        print(f"[0007] target not found: {target}", file=sys.stderr)
        return 1
    text = target.read_text(encoding="utf-8")
    if REMOVE_LINE not in text:
        if check_only:
            print("[0007] OK (REMOTE_CONTROL absent; check mode)")
        else:
            print("[0007] already absent (idempotent skip)")
        return 0
    if check_only:
        print("[0007] OK (REMOTE_CONTROL line present, would be removed; check mode)")
        return 0
    new_text = text.replace(REMOVE_LINE, "", 1)
    target.write_text(new_text, encoding="utf-8")
    print("[0007] removed REMOTE_CONTROL line from core/api/current.txt")
    return 0


if __name__ == "__main__":
    work_tree = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    sys.exit(main(work_tree))
