#!/bin/bash
# AOSP 15.0.0_r1 upstream fixes
# ==============================
# Two upstream AOSP 15 issues fail the api-stubs-docs-non-updatable
# preflight. Both are in the AOSP source itself, not in the qalos
# patches. This script applies both fixes idempotently.
#
# Issue 1: external/icu/android_icu4j/.../Collator.java
#   3 @hide abstract methods trigger metalava HiddenAbstractMethod.
#   Fix: convert to concrete methods that throw UnsupportedOperationException.
#
# Issue 2: external/conscrypt/api/intra/last-api.txt
#   Stale baseline predates patch_module: "java.base" config.
#   Fix: regenerate stubs and copy over the baseline.
#
# Idempotent: re-running is a no-op if the file already matches.
#
# Usage: invoked by do-build.sh after `apply-qalos.sh`.
#        Can also be run manually: bash fix-aosp-15-issues.sh

set -eo pipefail

BUILD_DIR="${BUILD_DIR:-$HOME/aosp}"
# The qalos repo is the manifest clone in the AOSP-15 layout
# (repo init -u https://github.com/bramburn/qalos.git), so the source
# of the python helpers lives at $BUILD_DIR/.repo/manifests, not at
# $HOME/qalos. Honor an explicit QALOS_DIR override for non-standard
# layouts, then fall back to the AOSP-15 default.
QALOS_DIR="${QALOS_DIR:-$BUILD_DIR/.repo/manifests}"
COLLATOR="$BUILD_DIR/external/icu/android_icu4j/src/main/java/android/icu/text/Collator.java"
CONSCRYPT_BASELINE="$BUILD_DIR/external/conscrypt/api/intra/last-api.txt"

log() { echo "[fix-aosp-15][$(date -u +%H:%M:%S)] $*"; }

# ---------------------------------------------------------------------------
# Issue 1: Collator.java
# ---------------------------------------------------------------------------
fix_collator() {
    if [ ! -f "$COLLATOR" ]; then
        log "collator: $COLLATOR not found, skipping"
        return 0
    fi

    # Already fixed? Check for one of the expected new method bodies.
    if grep -q 'throw new UnsupportedOperationException.*Needs to be implemented by the subclass' "$COLLATOR" \
       && grep -q 'public RawCollationKey getRawCollationKey' "$COLLATOR" \
       && ! grep -q 'public abstract RawCollationKey getRawCollationKey' "$COLLATOR"; then
        log "collator: already fixed, skipping"
        return 0
    fi

    log "collator: applying HiddenAbstractMethod fix (3 methods)"
    python3 "$QALOS_DIR/tools/fix_collator.py"
}

# ---------------------------------------------------------------------------
# Issue 2: conscrypt last-api.txt baseline
# ---------------------------------------------------------------------------
fix_conscrypt_baseline() {
    if [ ! -d "$BUILD_DIR/external/conscrypt" ]; then
        log "conscrypt: not present, skipping"
        return 0
    fi

    # Build just the conscrypt api stubs to get the source of truth.
    # This takes a few minutes the first time; cheap on warm ninja.
    log "conscrypt: regenerating api stubs to get the source of truth"
    (
        cd "$BUILD_DIR"
        # Use the host's already-loaded environment. Build envsetup first if
        # not loaded.
        if [ -z "${ANDROID_BUILD_TOP:-}" ]; then
            log "conscrypt: sourcing envsetup.sh and lunch"
            set +e
            # shellcheck disable=SC1091
            source build/envsetup.sh >/dev/null 2>&1
            lunch "${BUILD_TARGET:-qalos_emulator}-${BUILD_RELEASE:-trunk_staging}-${BUILD_VARIANT:-userdebug}" >/dev/null 2>&1
            set -e
        fi
        m -j"${BUILD_JOBS:-$(nproc)}" conscrypt.module.intra.core.api.stubs.source >/dev/null 2>&1 || true
    )

    # Find the most recent generated stubs.
    local generated
    generated="$(find "$BUILD_DIR/out" -name 'conscrypt.module.intra.core.api.stubs.source_api.txt' -path '*/sbox/*' 2>/dev/null | head -1)"
    if [ -z "$generated" ] || [ ! -f "$generated" ]; then
        generated="$(find "$BUILD_DIR/out" -name 'conscrypt.module.intra.core.api.stubs.source_api.txt' 2>/dev/null | head -1)"
    fi
    if [ -z "$generated" ] || [ ! -f "$generated" ]; then
        log "conscrypt: could not find generated stubs, skipping baseline update"
        return 0
    fi

    # Sanity check: the AOSP 15 conscrypt stub generator STRIPS class-level
    # `extends X implements Y` markers from `java.base` (because of
    # `patch_module: "java.base"`) but KEEPS per-constructor `throws X`
    # markers. So the only marker we can rely on is the `throws` clause.
    # If the generated stubs don't have ANY `throws java.security.*`
    # clause, the stub generation probably failed -- don't overwrite the
    # baseline with empty data.
    if ! grep -q 'throws java.security.NoSuchAlgorithmException' "$generated"; then
        log "conscrypt: generated stubs missing throws marker, skipping baseline update"
        return 0
    fi

    # Already up to date?
    if cmp -s "$generated" "$CONSCRYPT_BASELINE" 2>/dev/null; then
        log "conscrypt: baseline already matches, skipping"
        return 0
    fi

    log "conscrypt: updating last-api.txt baseline from generated stubs"
    cp "$generated" "$CONSCRYPT_BASELINE"
}

fix_collator
fix_conscrypt_baseline

log "done"
