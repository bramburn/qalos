#!/usr/bin/env bash
# qalos — apply qalos customizations to the AOSP working tree.
#
# The qalos repo (this one) is cloned into .repo/manifests/qalos by `repo
# init`. The qalos customizations (device tree, apps, vendor, plus the
# RemoteControlService Java source) live in subdirectories of that clone.
# The AOSP build system expects them at specific paths inside the working
# tree — `device/qalos/qalos_emulator/`, `packages/apps/QaLab/`,
# `frameworks/base/services/core/java/com/qalos/remotectl/`, etc. This
# script:
#
#   1. Runs `patches/check-patches.py` as a pre-flight so any broken
#      patch anchor is reported BEFORE the copy/apply step (a partial
#      apply is hard to roll back).
#   2. Copies the qalos overlay directories into the working tree
#      (`device/qalos/qalos_emulator/`, `packages/apps/QaLab/`,
#      `vendor/qalos/`, plus the framework services source).
#   3. Runs each of the three Python patch scripts (0002, 0003, 0004)
#      that gate the RemoteControlService in the AOSP framework. Each
#      edits one upstream AOSP file in place.
#
# Run this AFTER `repo init` and `repo sync`. It is idempotent: re-running
# it after you `git pull` in the qalos manifest repo will refresh the
# working tree to match the latest qalos sources. Both the copy step
# and each patch script are idempotent on their own.
#
# Usage:
#     ./tools/apply-qalos.sh
#     ./tools/apply-qalos.sh --force    # skip the patch pre-check
#
# Override the AOSP working tree location with WORK_TREE if you're running
# this from a different directory (e.g. the qalos-build-warm snapshot boots
# into $HOME, so the working tree is $HOME/aosp):
#     WORK_TREE=$HOME/aosp ./tools/apply-qalos.sh

set -euo pipefail

WORK_TREE="${WORK_TREE:-$(pwd)}"
QALOS_REPO="$WORK_TREE/.repo/manifests/qalos"
SKIP_PATCH_CHECK=0

for arg in "$@"; do
    case "$arg" in
        --force) SKIP_PATCH_CHECK=1 ;;
        --help|-h)
            sed -n '2,21p' "$0"
            exit 0
            ;;
    esac
done

if [ ! -d "$QALOS_REPO" ]; then
    echo "[apply-qalos] ERROR: $QALOS_REPO does not exist." >&2
    echo "[apply-qalos] Run \`repo init -u <qalos-repo> -b main\` first." >&2
    exit 1
fi

cd "$WORK_TREE"

# Allow the user to pull the latest qalos sources before applying.
if [ -d "$QALOS_REPO/.git" ]; then
    echo "[apply-qalos] updating qalos manifest repo at $QALOS_REPO"
    if ! (cd "$QALOS_REPO" && git pull --ff-only); then
        echo "[apply-qalos] ERROR: git pull failed in $QALOS_REPO." >&2
        echo "[apply-qalos] Refusing to continue. Resolve the pull (rebase," >&2
        echo "[apply-qalos] discard local commits, etc.) and re-run." >&2
        exit 2
    fi
fi

# Pre-flight: run the patch checker first. A partial apply is hard to
# roll back, so we want the user to know in advance if any patch is
# broken.
if [ "$SKIP_PATCH_CHECK" -eq 0 ] && [ -x "$(command -v python3 2>/dev/null)" ]; then
    echo "[apply-qalos] verifying patches against the AOSP working tree..."
    if ! python3 "$QALOS_REPO/packages/apps/RemoteControlService/patches/check-patches.py" "$WORK_TREE"; then
        echo "[apply-qalos] ERROR: one or more patches would not apply cleanly." >&2
        echo "[apply-qalos] Run with --force to apply the others anyway, or" >&2
        echo "[apply-qalos] see packages/apps/RemoteControlService/REBASE.md." >&2
        exit 3
    fi
fi

# Copy a qalos overlay directory into the AOSP working tree. Independent
# of any other path — a missing optional source does not fail the whole
# apply.
copy_path() {
    local src="$1"
    local dst="$2"
    if [ ! -d "$src" ]; then
        echo "[apply-qalos] skipping $dst (source $src not present in qalos repo)"
        return
    fi
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -r "$src" "$dst"
    echo "[apply-qalos] copied $dst"
}

# --- Existing overlay paths ---
copy_path "$QALOS_REPO/device/qalos/qalos_emulator"   device/qalos/qalos_emulator
copy_path "$QALOS_REPO/packages/apps/QaLab"           packages/apps/QaLab
copy_path "$QALOS_REPO/vendor/qalos"                  vendor/qalos

# --- New in v0: qalos RemoteControlService ---
# Copy the Java/AIDL source into the framework services tree.
copy_path \
    "$QALOS_REPO/packages/apps/RemoteControlService/src/com/qalos/remotectl" \
    frameworks/base/services/core/java/com/qalos/remotectl

# Apply the three Python "patches" that gate the service. Each script
# edits one upstream AOSP file in place; the script exits 1 if the
# anchor is not found. We surface that as a machine-readable line.
# (Patch 0001 used to edit services.core/Android.bp srcs but is no
# longer needed: AOSP 15's services.core-sources filegroup already
# has srcs: ["java/**/*.java"] which globs in our copied
# com/qalos/remotectl/*.java. See REBASE.md for the history.)
PATCH_DIR="$QALOS_REPO/packages/apps/RemoteControlService/patches"
for n in 0002 0003 0004; do
    patch_script="$(ls "$PATCH_DIR/${n}-"*.py 2>/dev/null || true)"
    if [ -z "$patch_script" ]; then
        echo "[apply-qalos] status=warn patch=${n} reason=missing-script"
        continue
    fi
    if python3 "$patch_script" "$WORK_TREE"; then
        echo "[apply-qalos] status=ok patch=$(basename "$patch_script")"
    else
        echo "[apply-qalos] status=err patch=$(basename "$patch_script")"
    fi
done

echo "[apply-qalos] done."
