#!/usr/bin/env bash
#
# scripts/aliyun-setup-base.sh - macOS/Linux twin of tools/aliyun-setup-base.ps1.
#
# One-time Aliyun base ECS setup. Creates a custom image called
# `qalos-build-warm` that subsequent on-demand builds launch from.
#
# Flow:
#   1. Launch a small base ECS using the smoke-test's VPC/vSwitch/SG/KeyPair.
#   2. Wait for it to be SSH-reachable.
#   3. SCP tools/setup-droplet.sh to the instance, run it.
#   4. Power the instance off (clean state for image capture).
#   5. Create a custom image from the stopped ECS.
#   6. Delete the base ECS.
#
# Cost: ~¥0.18 for ~10 min of e-c1m1.large runtime + ~¥1/mo for the custom
# image (8-12 GB). Re-run only when the AOSP build deps change.
#
# Usage:
#   ./scripts/aliyun-setup-base.sh
#   ./scripts/aliyun-setup-base.sh --instance-type ecs.u1-c1m8.2xlarge   # for real builds
#   ./scripts/aliyun-setup-base.sh --image-name qalos-build-warm-v2

set -euo pipefail

REGION="cn-hangzhou"
ZONE="cn-hangzhou-h"
BASE_NAME="qalos-base"
IMAGE_NAME="qalos-build-warm"
INSTANCE_TYPE="ecs.e-c1m1.large"   # 2 vCPU / 2 GB; swap in ecs.u1-c1m8.2xlarge for the real warm image
PREFIX="qalos-smoke"
QALOS_BRANCH="main"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)         REGION="$2"; shift 2 ;;
        --zone)           ZONE="$2"; shift 2 ;;
        --base-name)      BASE_NAME="$2"; shift 2 ;;
        --image-name)     IMAGE_NAME="$2"; shift 2 ;;
        --instance-type)  INSTANCE_TYPE="$2"; shift 2 ;;
        --branch)         QALOS_BRANCH="$2"; shift 2 ;;
        -h|--help)
            sed -n '2,30p' "$0"
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=lib/log.sh
source "$SCRIPT_DIR/lib/log.sh"
# shellcheck source=lib/aliyun-common.sh
source "$SCRIPT_DIR/lib/aliyun-common.sh"

require_aliyun
require_jq
require_ssh

# Load infra state from the smoke test
if [[ ! -f "$QALOS_STATE_FILE" ]]; then
    log_fatal "state file not found: $QALOS_STATE_FILE. Run scripts/aliyun-smoke-test.sh first (it bootstraps the VPC/vSwitch/SG/KeyPair)."
fi
eval "$(jq -r '@sh "REGION=\(.region) ZONE=\(.zone) VPC_ID=\(.vpcId) VSW_ID=\(.vswId) SG_ID=\(.sgId) KP_NAME=\(.keyPairName)"' "$QALOS_STATE_FILE")"

log_info "using $VPC_ID / $VSW_ID / $SG_ID / $KP_NAME from $QALOS_STATE_FILE"

# Find the most recent stock Ubuntu 22.04 image
IMAGE_ID="$(aliyon ecs DescribeImages --RegionId "$REGION" --ImageOwnerAlias system --OSType linux --Architecture x86_64 --PageSize 100 \
    | jq -r '.Images.Image
            | map(select(.OSName | test("ubuntu_22_04";"i")))
            | sort_by(.CreationTime) | reverse | .[0].ImageId // empty')"
if [[ -z "$IMAGE_ID" ]]; then
    log_fatal "no ubuntu_22_04 image in $REGION"
fi
log_info "image: $IMAGE_ID"

# Launch base ECS
now="$(date +%H%M%S)"
launched_name="${BASE_NAME}-${now}"
log_info "launching $launched_name ($INSTANCE_TYPE)..."
BASE_ID="$(aliyon ecs RunInstances \
    --RegionId "$REGION" \
    --ImageId "$IMAGE_ID" \
    --InstanceType "$INSTANCE_TYPE" \
    --SecurityGroupId "$SG_ID" \
    --VSwitchId "$VSW_ID" \
    --InstanceName "$launched_name" \
    --InstanceChargeType 'PostPaid' \
    --InternetMaxBandwidthOut 5 \
    --InternetChargeType 'PayByTraffic' \
    --SystemDisk.Category 'cloud_essd' \
    --SystemDisk.Size 100 \
    --KeyPairName "$KP_NAME" \
    --Amount 1 \
    | jq -r '.InstanceIdSets.InstanceIdSet[0]')"
log_info "base ECS: $BASE_ID"

# Watchdog
with_watchdog "$REGION" "$BASE_ID"

cleanup() {
    local exit_code=$?
    log_info "deleting base ECS $BASE_ID..."
    stop_watchdog
    aliyon ecs StopInstance  --RegionId "$REGION" --InstanceId "$BASE_ID" >/dev/null 2>&1 || true
    wait_for_instance_status "$REGION" "$BASE_ID" "Stopped" 60 || true
    aliyon ecs DeleteInstance --RegionId "$REGION" --InstanceId "$BASE_ID" --Force true >/dev/null 2>&1 || true
    return $exit_code
}
trap cleanup EXIT INT TERM

# Wait for Running + get public IP
public_ip=""
deadline=$(( $(date +%s) + 300 ))
while [[ $(date +%s) -lt $deadline ]]; do
    inst="$(aliyon ecs DescribeInstances --RegionId "$REGION" --InstanceIds "['$BASE_ID']" \
        | jq -r '.Instances.Instance[0] | "\(.Status)|\(.PublicIpAddress.IpAddress[0] // empty)"')"
    status="${inst%%|*}"
    public_ip="${inst#*|}"
    if [[ "$status" == "Running" && -n "$public_ip" ]]; then break; fi
    log_debug "  status=$status ip=$public_ip"
    sleep 5
done
if [[ -z "$public_ip" ]]; then
    log_fatal "base ECS did not become SSH-ready within 5 minutes"
fi
log_info "base ECS running at $public_ip"

# Wait for SSH
ssh_ready=0
for _ in $(seq 1 30); do
    if ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$public_ip" 'echo ready' >/dev/null 2>&1; then
        ssh_ready=1; break
    fi
    sleep 5
done
if [[ "$ssh_ready" -ne 1 ]]; then
    log_fatal "SSH not ready on $public_ip after 2.5 min. Aborting (base ECS will be force-deleted)."
fi

# Run setup-droplet.sh (the same AOSP setup script the DO path uses)
setup_script="$SCRIPT_DIR/../tools/setup-droplet.sh"
if [[ ! -f "$setup_script" ]]; then
    log_fatal "setup-droplet.sh not found at $setup_script"
fi
log_info "running $setup_script on the base ECS (5-10 min)..."
scp "$setup_script" "root@${public_ip}:/tmp/setup-droplet.sh"
ssh "root@$public_ip" 'bash /tmp/setup-droplet.sh'

# Power off
log_info "powering off base ECS for clean image capture..."
ssh "root@$public_ip" 'shutdown -h now' 2>/dev/null || true
wait_for_instance_status "$REGION" "$BASE_ID" "Stopped" 120 || true

# Create the custom image
log_info "creating custom image '$IMAGE_NAME'..."
WARM_IMAGE_ID="$(aliyon ecs CreateImage \
    --RegionId "$REGION" \
    --InstanceId "$BASE_ID" \
    --ImageName "$IMAGE_NAME" \
    --Description "qalos warm AOSP build image (AOSP $QALOS_BRANCH, base $INSTANCE_TYPE)" \
    | jq -r '.ImageId')"
log_info "custom image: $WARM_IMAGE_ID"

# Update the state file with the warm image id
save_state \
    "warmImageId=$WARM_IMAGE_ID" \
    "warmImageName=$IMAGE_NAME"

echo ""
log_info "DONE."
echo "  base ECS     : $BASE_ID  (deleted)"
echo "  warm image   : $WARM_IMAGE_ID ($IMAGE_NAME)"
echo "  region/zone  : $REGION / $ZONE"
echo "  state file   : $QALOS_STATE_FILE"
echo ""
echo "Next: run scripts/aliyun-build.sh to launch a build from this warm image."
