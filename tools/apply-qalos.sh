#!/usr/bin/env bash
# qalos — apply qalos customizations to the AOSP working tree.
#
# The qalos repo (this one) is cloned into .repo/manifests/qalos by `repo
# init`. The qalos customizations (device tree, apps, vendor) live in
# subdirectories of that clone. The AOSP build system expects them at specific
# paths inside the working tree — `device/qalos/qalos_emulator/`,
# `packages/apps/QaLab/`, etc. This script copies them into place.
#
# Run this AFTER `repo init` and `repo sync`. It is idempotent: re-running it
# after you `git pull` in the qalos manifest repo will refresh the working
# tree to match the latest qalos sources.
#
# Usage:
#     ./tools/apply-qalos.sh
#
# Override the AOSP working tree location with WORK_TREE if you're running
# this from a different directory (e.g. the qalos-build-warm snapshot boots
# into $HOME, so the working tree is $HOME/aosp):
#     WORK_TREE=$HOME/aosp ./tools/apply-qalos.sh

set -euo pipefail

WORK_TREE="${WORK_TREE:-$(pwd)}"
QALOS_REPO="$WORK_TREE/.repo/manifests/qalos"

if [ ! -d "$QALOS_REPO" ]; then
    echo "[apply-qalos] ERROR: $QALOS_REPO does not exist." >&2
    echo "[apply-qalos] Run \`repo init -u <qalos-repo> -b main\` first." >&2
    exit 1
fi

cd "$WORK_TREE"

# Allow the user to pull the latest qalos sources before applying.
if [ -d "$QALOS_REPO/.git" ]; then
    echo "[apply-qalos] updating qalos manifest repo at $QALOS_REPO"
    (cd "$QALOS_REPO" && git pull --ff-only || echo "[apply-qalos] WARN: git pull failed, using existing checkout")
fi

# Copy each qalos path into the AOSP working tree. Each block is independent
# so a missing optional path doesn't fail the whole apply.
apply_path() {
    local src="$1"
    local dst="$2"
    if [ ! -d "$src" ]; then
        echo "[apply-qalos] skipping $dst (source $src not present in qalos repo)"
        return
    fi
    mkdir -p "$(dirname "$dst")"
    rm -rf "$dst"
    cp -r "$src" "$dst"
    echo "[apply-qalos] applied $dst"
}

apply_path "$QALOS_REPO/device/qalos/qalos_emulator"   device/qalos/qalos_emulator
apply_path "$QALOS_REPO/packages/apps/QaLab"           packages/apps/QaLab
apply_path "$QALOS_REPO/vendor/qalos"                  vendor/qalos

echo "[apply-qalos] done."
