#!/usr/bin/env bash
# qalos — on-demand AOSP build script.
#
# Runs on a fresh DigitalOcean droplet created from the `qalos-build-warm`
# snapshot. Does the full AOSP build, uploads the resulting images to DO
# Spaces, then signals completion. The calling script (PowerShell or GH Actions)
# is responsible for destroying the droplet — but this script also installs a
# watchdog on the droplet itself so that even if the orchestrator loses its
# connection or crashes, the droplet self-destructs at MAX_RUNTIME_MINUTES
# instead of running forever and burning money.
#
# Required env:
#     SPACES_BUCKET    e.g. "qalos-builds"
#     SPACES_REGION    e.g. "lon1"
#     SPACES_KEY       DO Spaces access key
#     SPACES_SECRET    DO Spaces secret key
#
# Optional env (with defaults):
#     QALOS_REPO_URL     default: https://github.com/bramburn/qalos.git
#     AOSP_TAG           default: android-15.0.0_r1
#     BUILD_TARGET       default: qalos_emulator
#     BUILD_VARIANT      default: userdebug
#     MAX_RUNTIME_MINUTES default: 240  (4 hours; watchdog hard-kills the build at this point)
#     BUILD_JOBS         default: $(nproc)
#     BUILD_DIR          default: $HOME/aosp

set -euo pipefail

# ----------------------------------------------------------------------------
# Configuration
# ----------------------------------------------------------------------------
QALOS_REPO_URL="${QALOS_REPO_URL:-https://github.com/bramburn/qalos.git}"
AOSP_TAG="${AOSP_TAG:-android-15.0.0_r1}"
BUILD_TARGET="${BUILD_TARGET:-qalos_emulator}"
BUILD_VARIANT="${BUILD_VARIANT:-userdebug}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-240}"
BUILD_DIR="${BUILD_DIR:-$HOME/aosp}"

: "${SPACES_BUCKET:?SPACES_BUCKET is required}"
: "${SPACES_REGION:?SPACES_REGION is required}"
: "${SPACES_KEY:?SPACES_KEY is required}"
: "${SPACES_SECRET:?SPACES_SECRET is required}"

if [ -z "${BUILD_JOBS:-}" ]; then
    BUILD_JOBS="$(nproc)"
fi

ARTIFACT_DIR="$BUILD_DIR/out/target/product/$BUILD_TARGET"
TIMESTAMP="$(date -u +%Y%m%d-%H%M%S)"
LOG_DIR="$BUILD_DIR/.qalos-logs"
mkdir -p "$LOG_DIR"

log() { echo "[qalos][$(date -u +%H:%M:%S)] $*"; }

# ----------------------------------------------------------------------------
# Watchdog — self-destruct the droplet if MAX_RUNTIME_MINUTES is hit.
# This catches the case where the orchestrator (PowerShell/GH Actions) dies
# and never comes back to delete the droplet.
# ----------------------------------------------------------------------------
WATCHDOG_PID=""
shutdown_droplet() {
    log "watchdog: force-shutting down the droplet"
    # Kill any lingering build processes first to free resources fast.
    pkill -9 -f "java|cc1|gcc|ld|make|repo|emulator|kotlinc|d8|dex2oat" 2>/dev/null || true
    sleep 2
    shutdown -h now 2>/dev/null || poweroff 2>/dev/null || true
}
(
    sleep $((MAX_RUNTIME_MINUTES * 60))
    log "watchdog: build ran for $MAX_RUNTIME_MINUTES minutes, force-killing"
    shutdown_droplet
) &
WATCHDOG_PID=$!
trap 'kill $WATCHDOG_PID 2>/dev/null || true' EXIT

# ----------------------------------------------------------------------------
# Memory tuning — safer on small droplets.
# ----------------------------------------------------------------------------
export ANDROID_JACK_ARGS="${ANDROID_JACK_ARGS:--Xmx4g -Dfile.encoding=UTF-8}"
export MALLOC_ARENA_MAX=1
export USE_CCACHE=1
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"

# ----------------------------------------------------------------------------
# Step 1 — repo init (only the first time)
# ----------------------------------------------------------------------------
mkdir -p "$BUILD_DIR"
cd "$BUILD_DIR"

if [ ! -d ".repo" ]; then
    log "installing repo and initializing manifest"
    curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo
    chmod +x /usr/local/bin/repo
    repo init -u "$QALOS_REPO_URL" -b main
fi

# ----------------------------------------------------------------------------
# Step 2 — repo sync
# ----------------------------------------------------------------------------
log "syncing AOSP source at tag $AOSP_TAG (this can take a while on first run)"
repo sync -c -j"$BUILD_JOBS" --no-tags --no-clone-bundle 2>&1 | tee "$LOG_DIR/repo-sync.log"

# ----------------------------------------------------------------------------
# Step 3 — apply qalos customizations.
#
# tools/apply-qalos.sh copies the qalos device tree, apps, and vendor blobs
# from .repo/manifests/qalos into the AOSP working tree. It is idempotent
# and pulls the latest qalos sources first.
# ----------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "$0")" && pwd)"
log "applying qalos customizations"
WORK_TREE="$BUILD_DIR" bash "$SCRIPT_DIR/apply-qalos.sh"

# ----------------------------------------------------------------------------
# Step 4 — build
# ----------------------------------------------------------------------------
log "lunch $BUILD_TARGET-$BUILD_VARIANT"
source build/envsetup.sh
lunch "$BUILD_TARGET-$BUILD_VARIANT"

log "m -j$BUILD_JOBS (this takes 1-4 hours on a c-8 droplet)"
m -j"$BUILD_JOBS" 2>&1 | tee "$LOG_DIR/build.log"

# ----------------------------------------------------------------------------
# Step 5 — upload artifacts to DO Spaces
# ----------------------------------------------------------------------------
upload_artifact() {
    local file="$1"
    if [ ! -f "$file" ]; then
        log "WARN: $file not built, skipping upload"
        return
    fi
    log "uploading $(basename "$file") -> s3://$SPACES_BUCKET/$TIMESTAMP/"
    s3cmd put "$file" "s3://$SPACES_BUCKET/$TIMESTAMP/" \
        --host="$SPACES_REGION.digitaloceanspaces.com" \
        --access_key="$SPACES_KEY" \
        --secret_key="$SPACES_SECRET" \
        --no-check-md5 2>&1 | tail -3
}

for img in system.img boot.img userdata.img; do
    upload_artifact "$ARTIFACT_DIR/$img"
done

# Upload the build log too — saves a debug round-trip.
s3cmd put "$LOG_DIR/build.log" "s3://$SPACES_BUCKET/$TIMESTAMP/build.log" \
    --host="$SPACES_REGION.digitaloceanspaces.com" \
    --access_key="$SPACES_KEY" \
    --secret_key="$SPACES_SECRET" \
    --no-check-md5 2>&1 | tail -3

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
log "build complete at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
log "artifacts: s3://$SPACES_BUCKET/$TIMESTAMP/"

# Disable the watchdog now that we're done — the orchestrator will destroy
# the droplet. If the orchestrator is dead, the watchdog fires later.
kill $WATCHDOG_PID 2>/dev/null || true
WATCHDOG_PID=""

echo "QALOS_BUILD_DONE"
