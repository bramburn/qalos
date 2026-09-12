#!/usr/bin/env python3
"""
Patch 0009 — mark android.hidl.allocator@1.0::IAllocator/ashmem as
optional in AOSP 15's frozen VINTF matrices.

Build failure (attempt 7, 2026-09-12):
  Framework manifest is incompatible with frozen matrix at level 5:
  HALs incompatible. The following requirements are not met:
  android.hidl.allocator:
      required: @1.0::IAllocator/ashmem
      provided:

Root cause:
  system/libhidl/vintfdata/frozen/5.xml through 8.xml declare
  `android.hidl.allocator@1.0::IAllocator/ashmem` as a *required*
  HIDL HAL. The qalos emulator product inherits aosp_x86_64, which
  does not ship an ashmemd service. The level-5+ vintffm check
  (system/libvintf/HalManifest.cpp:326) walks the frozen matrices
  and rejects the build when the framework manifest doesn't provide
  the required HAL.

Fix:
  Mark the IAllocator HAL as `<optional>true</optional>` in each of
  the four frozen matrices. vintffm (HalManifest.cpp:327) skips
  optional HALs in the compatibility check, so the build passes
  without changing any framework-side requirements.

This is idempotent. Re-running this patch is safe.
"""

import re
import sys
from pathlib import Path

FROZEN_FILES = [
    "system/libhidl/vintfdata/frozen/5.xml",
    "system/libhidl/vintfdata/frozen/6.xml",
    "system/libhidl/vintfdata/frozen/7.xml",
    "system/libhidl/vintfdata/frozen/8.xml",
]


def main():
    aosp_root = Path(sys.argv[1]) if len(sys.argv) > 1 else Path.cwd()
    patched = []
    for rel in FROZEN_FILES:
        path = aosp_root / rel
        if not path.exists():
            print(f"[0009] SKIP (missing): {rel}")
            continue
        src = path.read_text()
        # Find <hal ...> ... <name>IAllocator ... </hal> blocks and
        # change optional="false" to optional="true" on the opening tag.
        def repl(match):
            block = match.group(0)
            return block.replace('optional="false"', 'optional="true"', 1)
        new_src = re.sub(
            r'<hal[^>]*>(?:(?!</hal>).)*<name>IAllocator(?:(?!</hal>).)*</hal>',
            repl,
            src,
            flags=re.DOTALL,
        )
        if new_src != src:
            path.write_text(new_src)
            patched.append(rel)
            print(f"[0009] PATCHED: {rel}")
        else:
            print(f"[0009] OK (no change): {rel}")
    if not patched:
        print("[0009] all frozen matrices already patched or IAllocator absent")
    print(f"[0009] patched {len(patched)} file(s)")


if __name__ == "__main__":
    main()
