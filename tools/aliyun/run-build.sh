#!/bin/bash
# qalos run-build wrapper -- sets env, runs do-build.sh, starts HTTP server.
# Used by the LLM-driven Aliyun Phase 4 launch.
#
# This is the "after do-build.sh" half of the build flow. The systemd unit
# `qalos-build` runs this script as its ExecStart. The script:
#   1. Sets env vars (TUNA mirror, no-shutdown-on-failure, watchdog timeout)
#   2. Runs /opt/qalos/tools/do-build.sh (the on-host AOSP build)
#   3. On exit (success or failure), starts the token-gated HTTP server that
#      serves the build artifacts for the mavis cron and the user to download.
#
# The HTTP server is started in the background (nohup) so this script can
# exit and the systemd unit can transition to "inactive". The cron checks
# `systemctl is-active qalos-build` -- inactive = build done, server is up.
#
# Prerequisites (set up by the UserData script that launches this wrapper):
#   /opt/qalos/tools/do-build.sh         -- the build script
#   /opt/qalos/tools/aliyun/qalos-serve-artifacts.py  -- the HTTP server
#   /tmp/qalos-public-ip.txt             -- the instance's public IP
#   /tmp/qalos-artifacts-token.txt       -- the uuid4 token for the HTTP server
set -eo pipefail

# Override shutdown_droplet so preflight failure does NOT kill the instance.
# The HTTP server needs the instance alive to serve the failure log to the
# mavis cron. (do-build.sh's shutdown_droplet reads this env var.)
export QALOS_NO_SHUTDOWN_ON_FAILURE=1

# On-host watchdog: 3 hours. AOSP 15 build on g7a.4xlarge takes 1-2 h;
# 3 h gives headroom for retries (repo sync, full m -jN).
export MAX_RUNTIME_MINUTES=180

# TUNA mirror for repo sync (drops cross-border to android.googlesource.com).
export QALOS_USE_TUNA_MIRROR=1

log() { echo "[qalos-run-build $(date -u +%H:%M:%S)] $*"; }

log "starting /opt/qalos/tools/do-build.sh"
/opt/qalos/tools/do-build.sh
BUILD_EXIT=$?
log "do-build.sh exited $BUILD_EXIT"

# After the build (success OR failure), start the HTTP server so the
# mavis cron and the user can download the artifacts.
ARTIFACT_DIR=/root/aosp/out/target/product/qalos_emulator
PUBLIC_IP=$(cat /tmp/qalos-public-ip.txt)
TOKEN=$(cat /tmp/qalos-artifacts-token.txt)
export QALOS_PUBLIC_IP="$PUBLIC_IP"

if [ -d "$ARTIFACT_DIR" ]; then
    log "starting HTTP server for $ARTIFACT_DIR (token ${TOKEN:0:8}...)"
    nohup python3 /opt/qalos/tools/aliyun/qalos-serve-artifacts.py \
        --port 8080 --token "$TOKEN" \
        --directory "$ARTIFACT_DIR" \
        --url-file /tmp/qalos-artifacts-url.txt \
        --pid-file /tmp/qalos-serve-artifacts.pid \
        --log-file /var/log/qalos-serve-artifacts.log \
        > /var/log/qalos-serve-artifacts.out 2>&1 &
    echo $! > /tmp/qalos-serve-artifacts.bg.pid
    sleep 3
    log "URL: $(cat /tmp/qalos-artifacts-url.txt 2>/dev/null || echo 'pending')"
else
    log "WARNING: artifact dir $ARTIFACT_DIR does not exist; HTTP server not started"
fi

exit $BUILD_EXIT
