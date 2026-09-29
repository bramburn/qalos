#!/usr/bin/env bash
# vendor/aqa/scripts/build_ecs.sh
#
# Build the AQA cheetah images on the Aliyun ECS instance.
#
# Assumes the AOSP archive has been extracted into the workspace AND
# tools/apply-qalos.sh has run at least once — vendor/aqa and device/qalos
# only exist in the working tree after that copy step, and `lunch` fails with
# "unknown product" without it.
#
# Usage (run from the AOSP root):
#   bash vendor/aqa/scripts/build_ecs.sh             # default = slim
#   bash vendor/aqa/scripts/build_ecs.sh full        # full image
#   bash vendor/aqa/scripts/build_ecs.sh slim        # slim image
#   bash vendor/aqa/scripts/build_ecs.sh full magisk # full + Magisk boot.img patch
#   bash vendor/aqa/scripts/build_ecs.sh slim magisk
#
# Env overrides:
#   JOBS=8    parallelism (default: min(nproc, 16))

set -euo pipefail

ROOT="$(pwd)"
cd "$ROOT"

echo "=== AQA Pixel 7 Pro Build ==="
echo "Root: $ROOT"
echo "Date: $(date -u +%FT%TZ)"
echo

# 1. The qalos/AQA layers must be present in the working tree.
if [ ! -f "vendor/aqa/aqa_cheetah_slim/aqa_cheetah_slim.mk" ]; then
    echo "ERROR: vendor/aqa/ is not in the working tree."
    echo "Run ./tools/apply-qalos.sh first (it copies vendor/aqa and"
    echo "device/qalos/qalos_cheetah* into the tree)."
    exit 1
fi

# 2. AOSP-public cheetah device tree (fetched by repo sync via upstream.xml).
if [ ! -f "device/google/pantah/aosp_cheetah.mk" ]; then
    echo "ERROR: device/google/pantah/aosp_cheetah.mk missing."
    echo "The AOSP device tree was not synced — re-check the source archive."
    exit 1
fi

# 3. Proprietary blobs. device-cheetah.mk pulls these in with
#    inherit-product-if-exists, so the build configures without them, but the
#    resulting image has no camera/audio/radio HALs. Warn rather than abort:
#    a config-only dry run is still useful.
if [ ! -d "vendor/google_devices" ]; then
    echo "WARNING: vendor/google_devices/ is absent — no proprietary blobs."
    echo "         The image will build but lack camera/audio/radio HALs."
    echo "         Populate it from the Google driver zips first (see"
    echo "         device/google/cheetah/README.md)."
    echo
fi

# 4. Source the Android build environment.
source build/envsetup.sh

# 5. Lunch. Target names are <product>-<variant>; there is no
#    "-trunk_staging-" segment on an android-15.0.0_r1 tag tree.
TARGET="${1:-slim}"
case "$TARGET" in
    full) PRODUCT="aqa_cheetah_full" ;;
    slim) PRODUCT="aqa_cheetah_slim" ;;
    *)
        echo "ERROR: target must be 'full' or 'slim' (got: '$TARGET')"
        exit 1
        ;;
esac

echo "Configuring target: ${PRODUCT}-userdebug"
lunch "${PRODUCT}-userdebug"

# 6. Parallelism.
#
# AOSP peaks at roughly 2 GB of RAM per compile job, so -j$(nproc) on a
# 32-vCPU / 128 GB instance oversubscribes and can OOM-kill ninja mid-build.
# Cap the default and let the caller raise it deliberately.
DEFAULT_JOBS=$(( $(nproc) < 16 ? $(nproc) : 16 ))
JOBS="${JOBS:-$DEFAULT_JOBS}"
echo "Compiling with -j${JOBS} (override with JOBS=<n>)"
START=$(date +%s)
m -j"$JOBS"
END=$(date +%s)

echo
echo "=== Build complete in $((END - START))s ==="
echo "Outputs: $ANDROID_PRODUCT_OUT"

# 7. Optional Magisk boot.img patch.
if [ "${2:-}" = "magisk" ]; then
    echo
    echo "=== Magisk boot.img patching ==="
    BOOT_IMG="$ANDROID_PRODUCT_OUT/boot.img"
    OUT_IMG="$ANDROID_PRODUCT_OUT/magisk_patched_boot.img"

    if [ ! -f "$BOOT_IMG" ]; then
        echo "ERROR: $BOOT_IMG not found"
        exit 1
    fi

    if [ -f "$OUT_IMG" ]; then
        echo "Already patched: $OUT_IMG"
    else
        MAGISK_VERSION="${MAGISK_VERSION:-27.0}"
        WORK=/tmp/aqa-magisk
        rm -rf "$WORK"
        mkdir -p "$WORK"

        echo "Downloading Magisk v${MAGISK_VERSION}..."
        wget -q -O "$WORK/Magisk.apk" \
            "https://github.com/topjohnwu/Magisk/releases/download/v${MAGISK_VERSION}/Magisk-v${MAGISK_VERSION}.apk"
        unzip -q -o "$WORK/Magisk.apk" -d "$WORK/apk"

        # Use Magisk's OWN boot_patch.sh rather than hand-rolling the ramdisk
        # edit. The cpio entries Magisk needs (magiskinit placement, overlay.d
        # layout, .backup/.magisk config) change between releases; a
        # hand-written patch silently produces an unbootable image.
        #
        # boot_patch.sh reads its binaries from $MAGISKBIN, which is where the
        # APK stores them for the target ABI.
        export MAGISKBIN="$WORK/apk/lib/arm64-v8a"

        (
            cd "$WORK/apk"
            # shellcheck disable=SC1091
            bash boot_patch.sh "$BOOT_IMG"
        ) || {
            echo "ERROR: Magisk boot_patch.sh failed."
            echo "Fallback (supported by upstream): install the Magisk app on a"
            echo "rooted/dev image, use Install -> Select and Patch a File, then"
            echo "flash the patched boot.img."
            exit 1
        }

        cp -f "$WORK/apk/new-boot.img" "$OUT_IMG"
        echo "Patched boot image: $OUT_IMG"
        echo "NOTE: this path is untested end-to-end as of 2026-09-25."
    fi
fi

echo
echo "=== Summary ==="
echo "Product:    $PRODUCT"
echo "Boot:       $ANDROID_PRODUCT_OUT/boot.img"
[ -f "$ANDROID_PRODUCT_OUT/magisk_patched_boot.img" ] && \
    echo "Magisk:     $ANDROID_PRODUCT_OUT/magisk_patched_boot.img"
echo "Output dir: $ANDROID_PRODUCT_OUT"