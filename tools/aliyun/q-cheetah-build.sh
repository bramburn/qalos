#!/bin/bash
# q-cheetah-build.sh — build 4 cheetah images on Aliyun ECS, push to HK OSS.
#
# Run on a fresh g7a.8xlarge Spot instance in cn-guangzhou-b, launched from
# the qalos warm image `m-7xv7h5qzkbvbrw7qmcty` (aosp-source-clean-20260914).
#
# Required env (set by launcher):
#   QALOS_BUILD_ID       unique build ID, e.g. "qalos-cheetah-20260926-225000"
#   HK_OSS_BUCKET        default "qalos-aosp-hk"
#   HK_OSS_ENDPOINT      default "oss-cn-hongkong.aliyuncs.com"
#   MAX_RUNTIME_MINUTES  default 180 (3h hard ceiling)
#
# Produces 4 image sets in HK OSS at oss://$HK_OSS_BUCKET/qalos-images/$QALOS_BUILD_ID/:
#   qalos_cheetah-userdebug/      {boot.img, system.img, vendor.img}      (vanilla)
#   qalos_cheetah-userdebug-magisk/ {boot.img (=boot_magisk.img)}        (vanilla + Magisk)
#   aqa_cheetah_full-userdebug/  {boot.img, system.img, vendor.img}      (full + aqa_server)
#   aqa_cheetah_slim-userdebug/  {boot.img, system.img, vendor.img}      (slim + aqa_server)
#
# On completion, writes /tmp/q_state/BUILD_DONE with UTC timestamp, then
# shutdown -h now. The mavis cron sees the instance in Stopped state and
# tears it down (DeleteInstance).

set -eo pipefail

# ---- config -----------------------------------------------------------------
QALOS_BUILD_ID="${QALOS_BUILD_ID:-qalos-cheetah-$(date +%Y%m%d-%H%M%S)}"
HK_OSS_BUCKET="${HK_OSS_BUCKET:-qalos-aosp-hk}"
HK_OSS_ENDPOINT="${HK_OSS_ENDPOINT:-oss-cn-hongkong.aliyuncs.com}"
MAX_RUNTIME_MINUTES="${MAX_RUNTIME_MINUTES:-360}"  # 6h; download + 3 builds + uploads
# The tar.zst was created on macmini2024 from /home/bramburn/aosp_new/ and so
# extracts preserving the directory name. When extracted to /root, it lands
# at /root/aosp_new/. We then symlink /root/aosp -> /root/aosp_new so the
# rest of the script can use the standard /root/aosp path.
AOSP_SRC=/root/aosp
AOSP_TREE=/root/aosp_new
OSS_OPTS="--endpoint $HK_OSS_ENDPOINT --part-size=104857600 --parallel=8 --bigfile-threshold=104857600"
LOG=/var/log/q-cheetah-build.log
STATE_DIR=/tmp/q_state

mkdir -p "$STATE_DIR"
exec >> "$LOG" 2>&1

log() { echo "[$(date -u +%FT%TZ)] [q-cheetah] $*"; }

log "================================================================="
log "QALOS_BUILD_ID       = $QALOS_BUILD_ID"
log "HK_OSS_BUCKET        = $HK_OSS_BUCKET"
log "HK_OSS_ENDPOINT      = $HK_OSS_ENDPOINT"
log "MAX_RUNTIME_MINUTES  = $MAX_RUNTIME_MINUTES"
log "AOSP_SRC             = $AOSP_SRC"
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

# ---- helper: upload one image set ------------------------------------------
upload_image_set() {
  local name=$1        # e.g. qalos_cheetah-userdebug
  local src=$2         # e.g. out/target/product/cheetah
  local boot_alt=$3    # optional: alt boot image (e.g. magisk) or empty
  log "uploading image set: $name (from $src)"
  for f in boot.img system.img vendor.img; do
    if [ -f "$src/$f" ]; then
      log "  cp $src/$f -> oss://$HK_OSS_BUCKET/qalos-images/$QALOS_BUILD_ID/$name/$f"
      ossutil cp "$src/$f" "oss://$HK_OSS_BUCKET/qalos-images/$QALOS_BUILD_ID/$name/$f" $OSS_OPTS \
        || log "  WARN: upload failed for $f"
    else
      log "  WARN: $src/$f not found"
    fi
  done
  if [ -n "$boot_alt" ] && [ -f "$src/$boot_alt" ]; then
    local target_name="${name}-magisk"
    log "  uploading magisk variant: $target_name"
    ossutil cp "$src/$boot_alt" "oss://$HK_OSS_BUCKET/qalos-images/$QALOS_BUILD_ID/$target_name/boot.img" $OSS_OPTS \
      || log "  WARN: magisk upload failed"
  fi
}

# ---- step 1: free up stale source from warm image ---------------------------
log "STEP 1: cleaning stale source (free disk for fresh extract)"
# Skip cleanup if tar.zst is already at expected size (download finished).
EXPECTED_SIZE=112876345779
if [ "$(stat -c %s /root/aosp_new.tar.zst 2>/dev/null || echo 0)" -eq "$EXPECTED_SIZE" ]; then
  log "  SKIP: aosp_new.tar.zst already at expected size (105.124 GiB)"
else
  rm -rf /root/aosp /root/aosp_new /root/aosp_new.tar.zst /root/.ccache /root/aosp_new.tar.zst.temp
fi
sync
df -h /root

# ---- step 2: download source from HK OSS (skip if already done) ------------
log "STEP 2: download aosp_new.tar.zst from HK OSS"
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
EXPECTED_SIZE=112876345779
if [ -s /root/aosp_new.tar.zst ] && [ "$(stat -c %s /root/aosp_new.tar.zst)" -eq "$EXPECTED_SIZE" ]; then
  log "  SKIP: aosp_new.tar.zst already at expected size ($(stat -c %s /root/aosp_new.tar.zst) bytes)"
elif [ -f "$SCRIPT_DIR/download-hk-oss.sh" ]; then
  log "  invoking download-hk-oss.sh"
  bash "$SCRIPT_DIR/download-hk-oss.sh" \
    "oss://$HK_OSS_BUCKET/aosp_new.tar.zst" \
    /root/aosp_new.tar.zst \
    "$HK_OSS_ENDPOINT"
else
  log "  WARN: download-hk-oss.sh not at $SCRIPT_DIR; falling back to plain ossutil"
  ossutil cp "oss://$HK_OSS_BUCKET/aosp_new.tar.zst" /root/aosp_new.tar.zst --force $OSS_OPTS
fi
log "download step complete; file size:"
ls -lh /root/aosp_new.tar.zst

# ---- step 3: extract --------------------------------------------------------
log "STEP 3: extracting tar.zst"
mkdir -p /root
tar --use-compress-program=unzstd -xf /root/aosp_new.tar.zst -C /root
# tar created /root/aosp_new/ on disk; symlink /root/aosp to it for the rest
# of the script's standard path.
if [ ! -e /root/aosp ]; then
  ln -s /root/aosp_new /root/aosp
fi
log "extraction complete"
df -h /root
du -sh /root/aosp_new 2>/dev/null | tail -1

# ---- step 4: switch .repo/manifests to feat/qa-lab-os-v1 ------------------
# The tar.zst was synced from `main`, but our cheetah + aqa overlays live
# on `feat/qa-lab-os-v1` (11 commits ahead). apply-qalos.sh reads from
# .repo/manifests/ — we must be on the right branch or the overlays don't
# exist when the script runs. github.com is reachable from cn-guangzhou-b
# (verified 2026-09-26); fetch + checkout is <30s.
log "STEP 4a: switching .repo/manifests to feat/qa-lab-os-v1"
cd /root/aosp_new/.repo/manifests
CURRENT_BRANCH=$(git rev-parse --abbrev-ref HEAD 2>/dev/null || echo "unknown")
log "  current branch: $CURRENT_BRANCH"
if [ "$CURRENT_BRANCH" != "feat/qa-lab-os-v1" ]; then
  log "  fetching origin feat/qa-lab-os-v1"
  git fetch origin feat/qa-lab-os-v1:feat/qa-lab-os-v1 2>&1 | tail -3
  log "  checking out feat/qa-lab-os-v1"
  git checkout feat/qa-lab-os-v1 2>&1 | tail -3
else
  log "  already on feat/qa-lab-os-v1 — fast-forward only"
  git fetch origin feat/qa-lab-os-v1 2>&1 | tail -3
  git merge --ff-only origin/feat/qa-lab-os-v1 2>&1 | tail -3
fi
log "  HEAD now at: $(git rev-parse --short HEAD) on $(git rev-parse --abbrev-ref HEAD)"

# ---- step 4b: apply qalos patches ------------------------------------------
log "STEP 4b: applying qalos patches (apply-qalos.sh)"
cd /root/aosp_new
.repo/manifests/tools/apply-qalos.sh

# ---- step 5: build env ------------------------------------------------------
log "STEP 5: sourcing build/envsetup.sh"
source build/envsetup.sh

# ccache config
export USE_CCACHE=1
export CCACHE_DIR=/root/.ccache
export CCACHE_MAXSIZE=50G
mkdir -p "$CCACHE_DIR"

# 8xlarge = 32 vCPU. AOSP 15 jack server is RAM-hungry; -j16 with
# ANDROID_JAVA_HOME_MAX_HEAP_SIZE=8G is the sweet spot for 128 GB RAM.
export MAX_NUM_JAVA_THREADS=8
log "build config: -j16, MAX_NUM_JAVA_THREADS=8, CCACHE_MAXSIZE=50G, nproc=$(nproc), memtotal=$(free -h | awk '/Mem:/ {print $2}')"

# ---- step 6: build qalos_cheetah (vanilla + magisk) -------------------------
log "STEP 6: lunch qalos_cheetah-userdebug"
lunch qalos_cheetah-userdebug

log "STEP 6a: m -j16 (full build)"
m -j16

log "STEP 6b: patching boot with magiskboot"
cd out/target/product/cheetah
if command -v magiskboot >/dev/null 2>&1; then
  magiskboot patch boot.img -o boot_magisk.img || log "WARN: magiskboot failed"
  ls -lh boot.img boot_magisk.img 2>/dev/null
else
  log "WARN: magiskboot not installed; downloading v27.0"
  # Magisk v27.0 is the last version that bundles magiskboot standalone.
  # Download just the magiskboot binary from the official Magisk release.
  curl -fsSL -o /tmp/magiskboot.zip https://github.com/topjohnwu/Magisk/releases/download/v27.0/Magisk-v27.0.apk
  which unzip || apt-get install -y unzip
  unzip -p /tmp/magiskboot.zip "lib/x86_64/libmagiskboot.so" > /usr/local/bin/magiskboot 2>/dev/null \
    || unzip -p /tmp/magiskboot.zip "lib/arm64-v8a/libmagiskboot.so" > /usr/local/bin/magiskboot
  chmod +x /usr/local/bin/magiskboot
  magiskboot patch boot.img -o boot_magisk.img || log "WARN: magiskboot patch failed"
fi
cd /root/aosp

upload_image_set "qalos_cheetah-userdebug" "out/target/product/cheetah" "boot_magisk.img"

# ---- step 7: build aqa_cheetah_full (incremental) ---------------------------
log "STEP 7: lunch aqa_cheetah_full-userdebug"
lunch aqa_cheetah_full-userdebug
log "STEP 7a: m -j16 (incremental)"
m -j16
upload_image_set "aqa_cheetah_full-userdebug" "out/target/product/aqa_cheetah_full" ""

# ---- step 8: build aqa_cheetah_slim (incremental) ---------------------------
log "STEP 8: lunch aqa_cheetah_slim-userdebug"
lunch aqa_cheetah_slim-userdebug
log "STEP 8a: m -j16 (incremental)"
m -j16
upload_image_set "aqa_cheetah_slim-userdebug" "out/target/product/aqa_cheetah_slim" ""

# ---- step 9: mark done ------------------------------------------------------
log "STEP 9: BUILD COMPLETE"
date -u +%FT%TZ > "$STATE_DIR/BUILD_DONE"
echo "$QALOS_BUILD_ID" > "$STATE_DIR/BUILD_ID"

kill $WATCHDOG_PID 2>/dev/null || true

# Honour NO_SHUTDOWN_AT_END: if set (by the cron pipeline to chain into a
# post-build 7z step), keep the instance alive for the next script.
if [ "${QALOS_NO_SHUTDOWN_AT_END:-0}" = "1" ]; then
  log "QALOS_NO_SHUTDOWN_AT_END=1 — leaving instance running for post-build steps"
  exit 0
fi

log "shutting down instance"
shutdown -h now
