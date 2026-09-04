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
# AOSP 15's `lunch` requires a 3-part combo <product>-<release>-<variant>. The
# release is a build-config label (not the AOSP tag); trunk_staging is the AOSP
# default for trunk and is what AndroidProducts.mk registers. Override with
# BUILD_RELEASE=foo to use a different label (e.g. a build-number cut).
BUILD_RELEASE="${BUILD_RELEASE:-trunk_staging}"
BUILD_VARIANT="${BUILD_VARIANT:-userdebug}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-240}"
BUILD_DIR="${BUILD_DIR:-$HOME/aosp}"

# SPACES_BUCKET is optional. When empty, the script skips the upload step and
# the orchestrator pulls artifacts back via SCP. This is the path used by the
# Aliyun and GCP orchestrators, which don't have DO Spaces credentials.
# When set (DO path), all four SPACES_* vars are required.
if [ -n "${SPACES_BUCKET:-}" ]; then
    : "${SPACES_REGION:?SPACES_REGION is required when SPACES_BUCKET is set}"
    : "${SPACES_KEY:?SPACES_KEY is required when SPACES_BUCKET is set}"
    : "${SPACES_SECRET:?SPACES_SECRET is required when SPACES_BUCKET is set}"
fi

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
#
# Use a lower concurrency here than for the AOSP build (j8) because the git
# fetches hit `android.googlesource.com` which has per-IP rate limits. Running
# 16 parallel git fetch processes gets us `RESOURCE_EXHAUSTED: Resource has been
# exhausted` and `HTTP 429` errors on a few of the ~1500 repos. j8 finishes
# in roughly the same wall time (AOSP source download is mostly bandwidth-bound
# to one server, not CPU-bound on the client) without the rate limit.
#
# Retry up to 3 times with exponential backoff. If `repo sync` still fails
# with the same RESOURCE_EXHAUSTED / HTTP 429 errors, fall back to j1.
# ----------------------------------------------------------------------------
log "syncing AOSP source at tag $AOSP_TAG (this can take a while on first run)"
REPO_SYNC_JOBS="${REPO_SYNC_JOBS:-8}"
REPO_SYNC_RETRIES="${REPO_SYNC_RETRIES:-3}"
SYNC_OK=0
# Note: do NOT use `... | tee "$LOG"` here. With `set -o pipefail`, a SIGPIPE
# to tee (which happens when repo sync exits quickly on an already-synced tree,
# as is the case with the warm snapshot) makes the pipe exit non-zero and
# `if ...; then` evaluate to false -- even though repo sync itself returned 0.
# That causes the script to think the sync failed and exit 1 ("FATAL: repo
# sync failed after all retries") even when the sync actually succeeded. Use a
# direct file redirect instead.
for attempt in $(seq 1 $REPO_SYNC_RETRIES); do
    if repo sync -c -j"$REPO_SYNC_JOBS" --no-tags --no-clone-bundle > "$LOG_DIR/repo-sync.log" 2>&1; then
        SYNC_OK=1
        break
    fi
    if [ $attempt -lt $REPO_SYNC_RETRIES ]; then
        log "repo sync attempt $attempt failed (likely RESOURCE_EXHAUSTED / HTTP 429 from android.googlesource.com); sleeping $((30 * attempt))s and retrying"
        sleep $((30 * attempt))
    fi
done
if [ $SYNC_OK -eq 0 ] && [ "${REPO_SYNC_FALLBACK_J1:-1}" = "1" ]; then
    log "fallback: retrying repo sync with -j1 --fail-fast (one fetch at a time)"
    if repo sync -c -j1 --fail-fast --no-tags --no-clone-bundle > "$LOG_DIR/repo-sync.log" 2>&1; then
        SYNC_OK=1
    fi
fi
if [ $SYNC_OK -eq 0 ]; then
    log "FATAL: repo sync failed after all retries. See $LOG_DIR/repo-sync.log"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 3 — apply qalos customizations.
#
# tools/apply-qalos.sh copies the qalos device tree, apps, and vendor blobs
# from .repo/manifests/qalos into the AOSP working tree. It is idempotent
# and pulls the latest qalos sources first.
#
# NOTE: the qalos repo IS the manifest in this AOSP-15 layout (the manifest
# is `repo init -u https://github.com/bramburn/qalos.git`), so apply-qalos.sh
# is checked out at `<aosp>/.repo/manifests/tools/apply-qalos.sh` after
# `repo sync`. It is NOT co-located with this do-build.sh script (which the
# orchestrator uploads to /tmp/). Derive the path from $BUILD_DIR instead of
# $0 to avoid the SCRIPT_DIR=$(dirname $0) trap that points at /tmp/.
# ----------------------------------------------------------------------------
APPLY_QALOS="$BUILD_DIR/.repo/manifests/tools/apply-qalos.sh"
if [ ! -f "$APPLY_QALOS" ]; then
    log "FATAL: $APPLY_QALOS not found after repo sync"
    log "The qalos manifest repo should have been checked out at .repo/manifests/"
    exit 1
fi
log "applying qalos customizations from $APPLY_QALOS"
WORK_TREE="$BUILD_DIR" bash "$APPLY_QALOS"

# ----------------------------------------------------------------------------
# Step 4 — build
# ----------------------------------------------------------------------------
# AOSP 15's `lunch` requires <product>-<release>-<variant> (3 parts, see
# envsetup.sh:442). The old <product>-<variant> form is rejected.
log "lunch $BUILD_TARGET-$BUILD_RELEASE-$BUILD_VARIANT"
source build/envsetup.sh
lunch "$BUILD_TARGET-$BUILD_RELEASE-$BUILD_VARIANT"

log "m -j$BUILD_JOBS (this takes 1-4 hours on a c-8 droplet)"
m -j"$BUILD_JOBS" 2>&1 | tee "$LOG_DIR/build.log"

# ----------------------------------------------------------------------------
# Step 5 — upload artifacts to DO Spaces (skipped if SPACES_BUCKET is empty)
# ----------------------------------------------------------------------------
if [ -n "${SPACES_BUCKET:-}" ]; then
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
else
    log "SPACES_BUCKET is empty -- skipping upload. Orchestrator will pull artifacts via SCP."
fi

# ----------------------------------------------------------------------------
# Done
# ----------------------------------------------------------------------------
log "build complete at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
if [ -n "${SPACES_BUCKET:-}" ]; then
    log "artifacts: s3://$SPACES_BUCKET/$TIMESTAMP/"
else
    log "artifacts on the instance under: $ARTIFACT_DIR/"
fi

# Disable the watchdog now that we're done — the orchestrator will destroy
# the droplet. If the orchestrator is dead, the watchdog fires later.
kill $WATCHDOG_PID 2>/dev/null || true
WATCHDOG_PID=""

echo "QALOS_BUILD_DONE"
