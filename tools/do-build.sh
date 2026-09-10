#!/usr/bin/env bash
# qalos ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â on-demand AOSP build script.
#
# Runs on a fresh DigitalOcean droplet created from the `qalos-build-warm`
# snapshot. Does the full AOSP build, uploads the resulting images to DO
# Spaces, then signals completion. The calling script (PowerShell or GH Actions)
# is responsible for destroying the droplet ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â but this script also installs a
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

# Do NOT use `set -u` here. AOSP 15's build/envsetup.sh (line 21) reads
# the unbound variable `TOP` as part of the build-top detection path.
# With `set -u`, that reference aborts envsetup before the lunch combo
# can resolve, killing the whole build. `set -e` + `-o pipefail` are
# enough to catch real errors without this false positive.
# See qalos AOSP-15 memory entry: "build/envsetup.sh line 21 TOP: unbound variable".
set -eo pipefail

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

# log() must be defined before any code that uses it. (Restored 2026-09-10;
# commit 550ef1e removed the original definition on line 102 but the
# intended re-insertion after BUILD_DIR was lost in a PowerShell
# regex-escape bug. Without this, the QALOS_USE_TUNA_MIRROR block on
# the next line aborts the script with "log: command not found"
# because of set -e.)
log() { echo "[qalos][$(date -u +%H:%M:%S)] $*"; }

# ----------------------------------------------------------------------------
# CN mirror hook (added 2026-09-09 for the Aliyun LLM-driven path)
# ----------------------------------------------------------------------------
# When QALOS_USE_CN_MIRROR=1 is set, override the fetch URL for the AOSP
# remote to Aliyun's own AOSP mirror (mirrors.aliyun.com, served via Aliyun
# CDN inside China). This avoids the TUNA rate-limit (capped at -j 4),
# the USTC git-repo stall (30+ min timeouts), and the cross-border latency
# to android.googlesource.com. The qalos manifest's
# <remote name="aosp" fetch="https://android.googlesource.com/"> is rewritten
# via `git config --global url.<...>.insteadOf` so the existing manifest
# needs no edit.
#
# History:
# - 2026-09-09: TUNA (mirrors.tuna.tsinghua.edu.cn) -- rate-limited to -j 4
# - 2026-09-10 AM: USTC (mirrors.ustc.edu.cn) -- git-repo stalled 30+ min
# - 2026-09-10 PM: Aliyun (mirrors.aliyun.com) -- Aliyun CDN, no rate-limit
#
# The env var is QALOS_USE_CN_MIRROR; QALOS_USE_TUNA_MIRROR=1 is also
# honoured for back-compat (both resolve to the same Aliyun redirect).
QALOS_USE_CN_MIRROR="${QALOS_USE_CN_MIRROR:-${QALOS_USE_TUNA_MIRROR:-0}}"
if [ "$QALOS_USE_CN_MIRROR" = "1" ]; then
    log "QALOS_USE_CN_MIRROR=1: redirecting android.googlesource.com -> mirrors.aliyun.com"
    git config --global url."https://mirrors.aliyun.com/android.googlesource.com/".insteadOf "https://android.googlesource.com/"
    # Aliyun mirror also serves the repo tool binary.
    git config --global url."https://mirrors.aliyun.com/android.googlesource.com/git-repo/".insteadOf "https://storage.googleapis.com/git-repo-downloads/"
    git config --global url."https://mirrors.aliyun.com/android.googlesource.com/git-repo/".insteadOf "https://gerrit.googlesource.com/git-repo"
    # Aliyun mirror also mirrors repo's own git-repo tool source.
    : "${REPO_SYNC_JOBS:=8}"
    log "  REPO_SYNC_JOBS=$REPO_SYNC_JOBS (Aliyun mirror, no rate-limit)"
fi

# QALOS_STOP_AFTER_PREFLIGHT (added 2026-09-09 for the Aliyun LLM-driven path)
# When set to 1, exit cleanly after the preflight metalava target builds.
# Useful for a sync + preflight-only run that validates the wiring before
# committing to a 1-1.5 h full build. Default 0 (run the full m -jN).
QALOS_STOP_AFTER_PREFLIGHT="${QALOS_STOP_AFTER_PREFLIGHT:-0}"

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

# ----------------------------------------------------------------------------
# Watchdog ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â self-destruct the droplet if MAX_RUNTIME_MINUTES is hit.
# This catches the case where the orchestrator (PowerShell/GH Actions) dies
# and never comes back to delete the droplet.
# ----------------------------------------------------------------------------
WATCHDOG_PID=""
shutdown_droplet() {
    log "watchdog: force-shutting down the droplet"
    # Kill any lingering build processes first to free resources fast.
    pkill -9 -f "java|cc1|gcc|ld|make|repo|emulator|kotlinc|d8|dex2oat" 2>/dev/null || true
    sleep 2
    # QALOS_NO_SHUTDOWN_ON_FAILURE (added 2026-09-09 for the Aliyun LLM-driven
    # path). When set to 1, do NOT actually shut down ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â just kill the build
    # processes and return. The LLM-driven wrapper needs the instance to
    # stay Running so the token-gated HTTP server can serve the failure
    # log to the mavis cron. Default 0 (original DO behaviour).
    if [ "${QALOS_NO_SHUTDOWN_ON_FAILURE:-0}" = "1" ]; then
        log "QALOS_NO_SHUTDOWN_ON_FAILURE=1: skipping shutdown, instance stays Running for artifact download"
        return 0
    fi
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
# Memory tuning ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â safer on small droplets.
# ----------------------------------------------------------------------------
export ANDROID_JACK_ARGS="${ANDROID_JACK_ARGS:--Xmx4g -Dfile.encoding=UTF-8}"
export MALLOC_ARENA_MAX=1
export USE_CCACHE=1
export CCACHE_DIR="${CCACHE_DIR:-$HOME/.ccache}"
export CCACHE_MAXSIZE="${CCACHE_MAXSIZE:-20G}"

# ----------------------------------------------------------------------------
# Step 1 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â repo init (only the first time)
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
# Step 2 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â repo sync
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
    if repo sync -c -j"$REPO_SYNC_JOBS" --depth 1 --no-tags --no-clone-bundle > "$LOG_DIR/repo-sync.log" 2>&1; then
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
    if repo sync -c -j1 --fail-fast --depth 1 --no-tags --no-clone-bundle > "$LOG_DIR/repo-sync.log" 2>&1; then
        SYNC_OK=1
    fi
fi
if [ $SYNC_OK -eq 0 ]; then
    log "FATAL: repo sync failed after all retries. See $LOG_DIR/repo-sync.log"
    exit 1
fi

# ----------------------------------------------------------------------------
# Step 3 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â apply qalos customizations.
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
# Step 4 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â build
# ----------------------------------------------------------------------------
# AOSP 15's `lunch` requires <product>-<release>-<variant> (3 parts, see
# envsetup.sh:442). The old <product>-<variant> form is rejected.
log "lunch $BUILD_TARGET-$BUILD_RELEASE-$BUILD_VARIANT"
source build/envsetup.sh
lunch "$BUILD_TARGET-$BUILD_RELEASE-$BUILD_VARIANT"

# ----------------------------------------------------------------------------
# Pre-flight: build ONLY the api-stubs target first (5-15 min on a 16 vCPU
# c3d-highmem-16, 10-25 min on a c-8). This is the step that catches the
# metalava `UnflaggedApi` / `@FlaggedApi` lint for any new permissions or
# APIs the qalos patches added to the framework. If this fails, abort
# immediately rather than waiting 2-4 hours to discover the same error
# in the full build. AGENTS.md ÃƒÆ’Ã¢â‚¬Å¡Ãƒâ€šÃ‚Â§8.2 documents why this is needed: the
# patch dry-run validates *mechanics* (regex match, apply cleanly), not
# *build behaviour*. The pre-flight closes that gap.
# ----------------------------------------------------------------------------
log "PREFLIGHT: building frameworks/base/api:checkapi (catches metalava UnflaggedApi early)"
# The preflight target was renamed in AOSP 15. The old
# `frameworks/base/api:api-stubs-docs-non-updatable` (the droidstubs
# doc-generation target) no longer exists; the closest AOSP 15 equivalent
# is `checkapi` (the metalava API compatibility check, which still catches
# the @FlaggedApi / UnflaggedApi lint we care about). If `checkapi` is
# also missing on some AOSP 15 sub-versions, fall back to building the
# whole `frameworks/base/api` package.
if ! m -j"$BUILD_JOBS" frameworks/base/api:checkapi 2>&1 | tee "$LOG_DIR/preflight.log"; then
    log "WARN: checkapi target missing, falling back to frameworks/base/api (whole package)"
    if ! m -j"$BUILD_JOBS" frameworks/base/api 2>&1 | tee -a "$LOG_DIR/preflight.log"; then
        log "FATAL: preflight metalava check failed -- new framework API is missing @FlaggedApi"
        log "  This means one of the qalos patches added a new <permission>, <uses-permission>, or"
        log "  public class/method that AOSP 15's metalava requires to be @FlaggedApi. The fix is"
        log "  one of: (a) add a UnflaggedApi entry to frameworks/base/api/lint-baseline.txt, or"
        log "  (b) define an aconfig flag and reference it in the new code. Do NOT launch a full"
        log "  cloud build until the preflight passes. See AGENTS.md Â§8.2 for the workflow."
        log "  Last 30 lines of preflight.log:"
        tail -30 "$LOG_DIR/preflight.log" | sed 's/^/  /'
        shutdown_droplet
        # If shutdown_droplet is a no-op (QALOS_NO_SHUTDOWN_ON_FAILURE=1 on
        # the Aliyun path), we still need to exit the script so the wrapper
        # can start the HTTP server. On the DO path shutdown_droplet actually
        # powers the instance off and this exit never runs.
        exit 1
    fi
fi
log "PREFLIGHT: checkapi built cleanly, proceeding to full build"

# QALOS_STOP_AFTER_PREFLIGHT: early-exit hook for the Aliyun LLM-driven
# path's sync + preflight validation phase. The systemd-run unit exits 0,
# the LLM's mavis cron sees the unit inactive, downloads the preflight log,
# and tears down the instance. Full m -jN is skipped.
if [ "$QALOS_STOP_AFTER_PREFLIGHT" = "1" ]; then
    log "QALOS_STOP_AFTER_PREFLIGHT=1: skipping full m -jN, exiting cleanly after preflight"
    kill $WATCHDOG_PID 2>/dev/null || true
    WATCHDOG_PID=""
    echo "QALOS_BUILD_DONE_PREFLIGHT_ONLY"
    exit 0
fi

log "m -j$BUILD_JOBS (this takes 1-4 hours on a c-8 droplet)"
m -j"$BUILD_JOBS" 2>&1 | tee "$LOG_DIR/build.log"

# ----------------------------------------------------------------------------
# Step 5 ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â upload artifacts to DO Spaces (skipped if SPACES_BUCKET is empty)
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

    # Upload the build log too ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â saves a debug round-trip.
    s3cmd put "$LOG_DIR/build.log" "s3://$SPACES_BUCKET/$TIMESTAMP/build.log" \
        --host="$SPACES_REGION.digitaloceanspaces.com" \
        --access_key="$SPACES_KEY" \
        --secret_key="$SPACES_SECRET" \
        --no-check-md5 2>&1 | tail -3
else
    log "SPACES_BUCKET is empty -- skipping upload. Orchestrator will pull artifacts via SCP."
fi

# ----------------------------------------------------------------------------
# Write the artifacts URL for the cron / user to download over HTTP
# ----------------------------------------------------------------------------
# The LLM-driven Aliyun build (and any future cloud build) downloads
# the artifacts via curl or a browser against a token-gated HTTP
# server (tools/aliyun/qalos-serve-artifacts.py) that the systemd
# unit starts in ExecStartPost after this script exits. The server
# reads its URL from /tmp/qalos-artifacts-url.txt; the cron and the
# user both read this file.
#
# Write the URL file with a placeholder; the systemd unit's
# ExecStartPost overwrites it with the real URL after the server
# starts. The placeholder lets the cron poll for either the
# placeholder (server not yet up) or the real URL (server up,
# ready to download).
ARTIFACTS_URL_FILE="/tmp/qalos-artifacts-url.txt"
if [ -n "${QALOS_ARTIFACTS_PUBLIC_URL:-}" ]; then
    # The systemd unit passed us the public URL; write it now
    # so the cron sees it before the server is up.
    echo "$QALOS_ARTIFACTS_PUBLIC_URL/" > "$ARTIFACTS_URL_FILE"
    log "artifacts URL file: $ARTIFACTS_URL_FILE (set by systemd)"
else
    # The server is going to overwrite this file. Write a
    # placeholder so the cron knows the build is done but the
    # server hasn't started yet.
    echo "pending" > "$ARTIFACTS_URL_FILE"
    log "artifacts URL file: $ARTIFACTS_URL_FILE (placeholder; the systemd unit's ExecStartPost will overwrite)"
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

# Disable the watchdog now that we're done ÃƒÆ’Ã‚Â¢ÃƒÂ¢Ã¢â‚¬Å¡Ã‚Â¬ÃƒÂ¢Ã¢â€šÂ¬Ã‚Â the orchestrator will destroy
# the droplet. If the orchestrator is dead, the watchdog fires later.
kill $WATCHDOG_PID 2>/dev/null || true
WATCHDOG_PID=""

echo "QALOS_BUILD_DONE"
