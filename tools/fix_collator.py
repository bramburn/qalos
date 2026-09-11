#!/usr/bin/env python3
"""Targeted fix for metalava HiddenAbstractMethod errors in Collator.java.

The AOSP 15.0.0_r1 metalava tool does NOT respect
@SuppressWarnings("HiddenAbstractMethod") on the 3 specific methods that
need it. The fix: convert ONLY those 3 abstract method declarations into
concrete methods that throw UnsupportedOperationException, matching the
pattern used by setMaxVariable(int) in the same file.

The 3 lines to fix (in the AOSP 15.0.0_r1 source, anchored by their
unique signatures):
  - getRawCollationKey(String source, RawCollationKey key)  -> RawCollationKey
  - setVariableTop(String varTop)                            -> int
  - setVariableTop(int varTop)                               -> void

We identify them by their unique signatures, then replace ONLY the single
"public abstract <signature>;" line. Every other abstract method in the
file is left alone (they are required by RuleBasedCollator and friends).

Idempotent: re-running is a no-op if the methods are already concrete.
"""
import re
import sys

FILE = "/root/aosp/external/icu/android_icu4j/src/main/java/android/icu/text/Collator.java"

# (regex, replacement_template) — one per target method.
# Each regex matches the EXACT "public abstract <ret> <name>(<args>);"
# declaration, anchored on the method signature. count=1 in subn() means
# we only fix the first occurrence of each, which is exactly the one
# method we care about.
TARGETS = [
    # getRawCollationKey(String, RawCollationKey) -> RawCollationKey
    (
        re.compile(
            r'^(    public abstract )'
            r'(RawCollationKey )'
            r'(getRawCollationKey\(String source,\s*\n\s*RawCollationKey key\))'
            r'(;)$',
            re.MULTILINE,
        ),
        r'    public \2\3 {\n'
        r'        throw new UnsupportedOperationException("Needs to be implemented by the subclass.");\n'
        r'    }',
    ),
    # setVariableTop(String) -> int
    (
        re.compile(
            r'^(    public abstract )'
            r'(int )'
            r'(setVariableTop\(String varTop\))'
            r'(;)$',
            re.MULTILINE,
        ),
        r'    public \2\3 {\n'
        r'        throw new UnsupportedOperationException("Needs to be implemented by the subclass.");\n'
        r'    }',
    ),
    # setVariableTop(int) -> void
    (
        re.compile(
            r'^(    public abstract )'
            r'(void )'
            r'(setVariableTop\(int varTop\))'
            r'(;)$',
            re.MULTILINE,
        ),
        r'    public \2\3 {\n'
        r'        throw new UnsupportedOperationException("Needs to be implemented by the subclass.");\n'
        r'    }',
    ),
]


def main():
    with open(FILE) as f:
        text = f.read()

    # Idempotency check: if none of the targets are still abstract, we're done.
    if (not re.search(r'public abstract RawCollationKey getRawCollationKey', text)
            and not re.search(r'public abstract int setVariableTop', text)
            and not re.search(r'public abstract void setVariableTop', text)):
        print(f"OK: {FILE} already fixed (no matching abstract methods)")
        return 0

    new_text = text
    total = 0
    for i, (pat, repl) in enumerate(TARGETS):
        new_text, n = pat.subn(repl, new_text, count=1)
        total += n
        if n != 1:
            print(f"ERROR: target {i} matched {n} times (expected 1). Aborting.", file=sys.stderr)
            return 1

    # Strip the now-redundant @SuppressWarnings("HiddenAbstractMethod")
    # annotations immediately preceding the three lines we just fixed. We
    # handle both: (a) suppress directly above public, and (b) suppress
    # above @Deprecated which is above public.
    new_text = re.sub(
        r'    @SuppressWarnings\("HiddenAbstractMethod"\)\n'
        r'    (public RawCollationKey getRawCollationKey|public int setVariableTop|public void setVariableTop)\b',
        r'    \1',
        new_text,
    )
    new_text = re.sub(
        r'    @SuppressWarnings\("HiddenAbstractMethod"\)\n'
        r'    @Deprecated\n'
        r'    (public int setVariableTop|public void setVariableTop)\b',
        r'    @Deprecated\n    \1',
        new_text,
    )

    if new_text == text:
        print("ERROR: no changes made.", file=sys.stderr)
        return 1

    with open(FILE, 'w') as f:
        f.write(new_text)

    print(f"OK: replaced {total} abstract method declarations in {FILE}")
    print(f"     new file size: {len(new_text)} bytes (was {len(text)})")
    return 0


if __name__ == "__main__":
    sys.exit(main())
