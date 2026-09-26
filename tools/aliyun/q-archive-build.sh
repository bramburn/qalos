#!/bin/bash
# q-archive-build.sh — post-build 7z archive step.
#
# Runs AFTER q-cheetah-build.sh has completed (BUILD_DONE marker exists) and
# after the 4 image sets have been uploaded to HK OSS. Compresses the AOSP
# source tree on the ECS to 7z with LZMA2 -mx=9 (typically 5-15% smaller
# than tar.zst level 6), uploads the .7z to HK OSS, then deletes the original
# .tar.zst to save storage costs.
#
# Required env (set by launcher / cron):
#   QALOS_BUILD_ID       unique build ID
#   HK_OSS_BUCKET        default "qalos-aosp-hk"
#   HK_OSS_ENDPOINT      default "oss-cn-hongkong.aliyuncs.com"
#   MAX_RUNTIME_MINUTES  default 240 (4h; 7z + upload)
#
# Markers:
#   reads  /tmp/q_state/BUILD_DONE
#   writes /tmp/q_state/ARCHIVE_DONE

set -eo pipefail

QALOS_BUILD_ID="${QALOS_BUILD_ID:-qalos-cheetah-$(date +%Y%m%d-%H%M%S)}"
HK_OSS_BUCKET="${HK_OSS_BUCKET:-qalos-aosp-hk}"
HK_OSS_ENDPOINT="${HK_OSS_ENDPOINT:-oss-cn-hongkong.aliyuncs.com}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-240}"
LOG=/var/log/q-archive-build.log
STATE_DIR=/tmp/q_state

mkdir -p "$STATE_DIR"
exec >> "$LOG" 2>&1

log() { echo "[$(date -u +%FT%TZ)] [q-archive] $*"; }

log "================================================================="
log "QALOS_BUILD_ID       = $QALOS_BUILD_ID"
log "HK_OSS_BUCKET        = $HK_OSS_BUCKET"
log "HK_OSS_ENDPOINT      = $HK_OSS_ENDPOINT"
log "MAX_RUNTIME_MINUTES  = $MAX_RUNTIME_MINUTES"
log "================================================================="

# ---- watchdog: hard shutdown after MAX_RUNTIME_MINUTES -----------------------
(
  sleep $((MAX_RUNTIME_MINUTES * 60))
  log "WATCHDOG FIRED at MAX_RUNTIME_MINUTES=$MAX_RUNTIME_MINUTES"
  date -u +%FT%TZ > "$STATE_DIR/WATCHDOG_FIRED"
  shutdown -h now
) &
WATCHDOG_PID=$!
trap 'kill $WATCHDOG_PID 2>/dev/null || true' EXIT

# ---- sanity check: BUILD_DONE exists ---------------------------------------
if [ ! -f "$STATE_DIR/BUILD_DONE" ]; then
  log "FATAL: BUILD_DONE marker not found; aborting"
  exit 1
fi

# ---- step 1: install p7zip if missing ---------------------------------------
if ! command -v 7z >/dev/null 2>&1; then
  log "STEP 1: installing p7zip-full"
  apt-get update -qq && apt-get install -y -qq p7zip-full
fi
7z | head -1

# ---- step 2: 7z -mx=9 on the AOSP source tree -----------------------------
AOSP_SRC=/root/aosp
ARCHIVE=/root/aosp_new.7z
log "STEP 2: 7z a -mx=9 $ARCHIVE $AOSP_SRC"
log "  source tree size:"
du -sh "$AOSP_SRC" 2>/dev/null | tail -1
df -h /root

time 7z a -mx=9 -mmt=8 -bb1 "$ARCHIVE" "$AOSP_SRC" 2>&1 | tail -20

log "7z complete; archive size:"
ls -lh "$ARCHIVE"

# ---- step 3: upload archive to HK OSS --------------------------------------
log "STEP 3: uploading $ARCHIVE to oss://$HK_OSS_BUCKET/qalos-sources/$QALOS_BUILD_ID/aosp_new.7z"
OSS_OPTS="--endpoint $HK_OSS_ENDPOINT --part-size=104857600 --parallel=8 --bigfile-threshold=104857600"
ossutil cp "$ARCHIVE" "oss://$HK_OSS_BUCKET/qalos-sources/$QALOS_BUILD_ID/aosp_new.7z" $OSS_OPTS

log "upload complete; verifying"
ossutil stat "oss://$HK_OSS_BUCKET/qalos-sources/$QALOS_BUILD_ID/aosp_new.7z" --endpoint "$HK_OSS_ENDPOINT" | head -10

# ---- step 4: delete original tar.zst from HK OSS ----------------------------
log "STEP 4: deleting oss://$HK_OSS_BUCKET/aosp_new.tar.zst"
ossutil rm "oss://$HK_OSS_BUCKET/aosp_new.tar.zst" --endpoint "$HK_OSS_ENDPOINT" -f

# ---- step 5: mark done ------------------------------------------------------
log "STEP 5: ARCHIVE COMPLETE"
date -u +%FT%TZ > "$STATE_DIR/ARCHIVE_DONE"
echo "$QALOS_BUILD_ID" > "$STATE_DIR/ARCHIVE_BUILD_ID"

kill $WATCHDOG_PID 2>/dev/null || true
log "shutting down instance"
shutdown -h now
