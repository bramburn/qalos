#!/usr/bin/env bash
#
# scripts/aliyun-smoke-test.sh - macOS/Linux twin of tools/aliyun-smoke-test.ps1.
#
# Purpose: prove the Aliyun CLI + credentials + region work end-to-end by
# spinning up the smallest possible ECS that is actually in stock,
# confirming it transitions to Running, and deleting it.
#
# Supporting infrastructure (VPC / vSwitch / Security Group / KeyPair named
# `qalos-smoke-*`) is kept around because it's free and will be reused by
# aliyun-setup-base.sh / aliyun-build.sh later. Their IDs are written to
# .pi/aliyun-state.json for the build script to consume.
#
# Mirrors the four-safety-net pattern from doctl-build.ps1:
#   1. trap + cleanup function  - instance is force-deleted on any exit path
#   2. background nohup watchdog - force-deletes if parent dies
#   3. (n/a - this is a 60-second smoke test, no on-host watchdog needed)
#   4. (n/a - local only, no GH Actions path)
#
# Cost: under ¥0.05. ecs.e-c1m1.large at ~¥0.18/hr, held < 90 s.
#
# Usage:
#   ./scripts/aliyun-smoke-test.sh                  # default region/zone
#   ./scripts/aliyun-smoke-test.sh --zone cn-hangzhou-i   # different zone

set -euo pipefail

# Args
REGION="cn-hangzhou"
ZONE="cn-hangzhou-h"
PREFIX="qalos-smoke"
WAIT_SECONDS=120
while [[ $# -gt 0 ]]; do
    case "$1" in
        --region)   REGION="$2"; shift 2 ;;
        --zone)     ZONE="$2"; shift 2 ;;
        --prefix)   PREFIX="$2"; shift 2 ;;
        --wait)     WAIT_SECONDS="$2"; shift 2 ;;
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

# -----------------------------------------------------------------------------
# 1. Auth check
# -----------------------------------------------------------------------------
log_info "aliyun version: $("$QALOS_ALIYUN" version | head -1)"
if ! "$QALOS_ALIYUN" configure list 2>/dev/null | grep -qE 'default[[:space:]]+\*'; then
    log_fatal "no default aliyun profile. Run 'aliyun configure' first."
fi
log_info "auth: default profile present, region $REGION"

# -----------------------------------------------------------------------------
# 2. Pick the smallest instance type that is IN STOCK in this zone
# -----------------------------------------------------------------------------
log_info "checking stock in $ZONE..."
CHOSEN_TYPE="$(smallest_in_stock_instance_type "$REGION" "$ZONE")"
log_info "chosen instance type: $CHOSEN_TYPE"

# -----------------------------------------------------------------------------
# 3. Resolve or create VPC
# -----------------------------------------------------------------------------
VPC_NAME="${PREFIX}-vpc"
VPC_ID=""
existing="$(aliyun vpc DescribeVpcs --RegionId "$REGION" --VpcName "$VPC_NAME" | jq -r '.Vpcs.Vpc[0].VpcId // empty')"
if [[ -n "$existing" ]]; then
    VPC_ID="$existing"
    log_debug "reusing VPC $VPC_ID ($VPC_NAME)"
else
    VPC_ID="$(aliyun vpc CreateVpc --RegionId "$REGION" --CidrBlock '172.16.0.0/16' --VpcName "$VPC_NAME" --Description "qalos smoke test VPC ($PREFIX)" | jq -r '.VpcId')"
    log_info "created VPC $VPC_ID"
fi

# -----------------------------------------------------------------------------
# 4. Resolve or create vSwitch
# -----------------------------------------------------------------------------
VSW_NAME="${PREFIX}-vsw"
VSW_ID=""
existing="$(aliyun vpc DescribeVSwitches --RegionId "$REGION" --VpcId "$VPC_ID" --VSwitchName "$VSW_NAME" | jq -r '.VSwitches.VSwitch[0].VSwitchId // empty')"
if [[ -n "$existing" ]]; then
    VSW_ID="$existing"
    VSW_ZONE="$(aliyun vpc DescribeVSwitches --RegionId "$REGION" --VpcId "$VPC_ID" --VSwitchName "$VSW_NAME" | jq -r '.VSwitches.VSwitch[0].ZoneId')"
    log_debug "reusing vSwitch $VSW_ID in $VSW_ZONE"
else
    VSW_ID="$(aliyun vpc CreateVSwitch --RegionId "$REGION" --VpcId "$VPC_ID" --ZoneId "$ZONE" --CidrBlock '172.16.1.0/24' --VSwitchName "$VSW_NAME" | jq -r '.VSwitchId')"
    VSW_ZONE="$ZONE"
    log_info "created vSwitch $VSW_ID in $VSW_ZONE"
fi

# -----------------------------------------------------------------------------
# 5. Resolve or create Security Group + SSH inbound rule
# -----------------------------------------------------------------------------
SG_NAME="${PREFIX}-sg"
SG_ID=""
existing="$(aliyun ecs DescribeSecurityGroups --RegionId "$REGION" --VpcId "$VPC_ID" --SecurityGroupName "$SG_NAME" | jq -r '.SecurityGroups.SecurityGroup[0].SecurityGroupId // empty')"
if [[ -n "$existing" ]]; then
    SG_ID="$existing"
    log_debug "reusing Security Group $SG_ID"
else
    SG_ID="$(aliyun ecs CreateSecurityGroup --RegionId "$REGION" --VpcId "$VPC_ID" --SecurityGroupName "$SG_NAME" --Description "qalos smoke test SG ($PREFIX)" | jq -r '.SecurityGroupId')"
    log_info "created Security Group $SG_ID"
fi
# Authorize SSH 22/22 from 0.0.0.0/0 (idempotent: returns the existing rule on retry)
aliyun ecs AuthorizeSecurityGroup \
    --RegionId "$REGION" --SecurityGroupId "$SG_ID" \
    --IpProtocol 'tcp' --PortRange '22/22' --SourceCidrIp '0.0.0.0/0' \
    --Description 'qalos smoke test SSH' >/dev/null 2>&1 || true
log_debug "authorized SSH 22/22 from 0.0.0.0/0"

# -----------------------------------------------------------------------------
# 6. Resolve or import KeyPair
# -----------------------------------------------------------------------------
KP_NAME="${PREFIX}-key"
KP_ID=""
existing="$(aliyun ecs DescribeKeyPairs --RegionId "$REGION" --KeyPairName "$KP_NAME" | jq -r '.KeyPairs.KeyPair[0].KeyPairId // empty')"
if [[ -n "$existing" ]]; then
    KP_ID="$existing"
    log_debug "reusing KeyPair $KP_NAME ($KP_ID)"
else
    pubkey_path="$HOME/.ssh/id_rsa.pub"
    if [[ ! -f "$pubkey_path" ]]; then
        log_warn "no ~/.ssh/id_rsa.pub found; generating ed25519 keypair for qalos-aliyun"
        mkdir -p "$HOME/.ssh"
        chmod 700 "$HOME/.ssh"
        ssh-keygen -t ed25519 -f "$HOME/.ssh/id_ed25519_qalos_aliyun" -N '' -C 'qalos-aliyun' >/dev/null
        pubkey_path="$HOME/.ssh/id_ed25519_qalos_aliyun.pub"
    fi
    pubkey_text="$(cat "$pubkey_path")"
    aliyun ecs ImportKeyPair --RegionId "$REGION" --KeyPairName "$KP_NAME" --PublicKeyBody "$pubkey_text" >/dev/null
    log_info "imported KeyPair $KP_NAME"
fi

# -----------------------------------------------------------------------------
# 7. Find the most recent stock Ubuntu 22.04 image
# -----------------------------------------------------------------------------
IMAGE_ID="$(aliyon ecs DescribeImages --RegionId "$REGION" --ImageOwnerAlias system --OSType linux --Architecture x86_64 --PageSize 100 \
    | jq -r '.Images.Image
            | map(select(.OSName | test("ubuntu";"i") and (. | test("22.04";"i"))) )
            | sort_by(.CreationTime) | reverse | .[0].ImageId // empty')"
if [[ -z "$IMAGE_ID" ]]; then
    IMAGE_ID="$(aliyon ecs DescribeImages --RegionId "$REGION" --ImageOwnerAlias system --OSType linux --Architecture x86_64 --PageSize 100 \
        | jq -r '.Images.Image
                | map(select(.OSName | test("ubuntu_22";"i"))) 
                | sort_by(.CreationTime) | reverse | .[0].ImageId // empty')"
fi
if [[ -z "$IMAGE_ID" ]]; then
    log_fatal "no Ubuntu 22.04 image found in $REGION"
fi
log_info "image: $IMAGE_ID"

# -----------------------------------------------------------------------------
# 8. RunInstances
# -----------------------------------------------------------------------------
INSTANCE_NAME="${PREFIX}-$(date +%H%M%S)"
log_info "launching $INSTANCE_NAME (type: $CHOSEN_TYPE)..."
INSTANCE_ID="$(aliyon ecs RunInstances \
    --RegionId "$REGION" \
    --ImageId "$IMAGE_ID" \
    --InstanceType "$CHOSEN_TYPE" \
    --SecurityGroupId "$SG_ID" \
    --VSwitchId "$VSW_ID" \
    --InstanceName "$INSTANCE_NAME" \
    --InstanceChargeType 'PostPaid' \
    --InternetMaxBandwidthOut '5' \
    --InternetChargeType 'PayByTraffic' \
    --SystemDisk.Category 'cloud_essd' \
    --SystemDisk.Size '40' \
    --KeyPairName "$KP_NAME" \
    --Amount '1' \
    | jq -r '.InstanceIdSets.InstanceIdSet[0]')"
log_info "launched $INSTANCE_ID"

# -----------------------------------------------------------------------------
# 9. Background watchdog (safety net #2)
# -----------------------------------------------------------------------------
with_watchdog "$REGION" "$INSTANCE_ID"

# -----------------------------------------------------------------------------
# 10. Wait for Running
# -----------------------------------------------------------------------------
PUBLIC_IP=""
deadline=$(( $(date +%s) + WAIT_SECONDS ))
start_ts=$(date +%s)
status=""
while [[ $(date +%s) -lt $deadline ]]; do
    inst="$(aliyon ecs DescribeInstances --RegionId "$REGION" --InstanceIds "['$INSTANCE_ID']" \
        | jq -r '.Instances.Instance[0] | "\(.Status)|\(.PublicIpAddress.IpAddress[0] // empty)"')"
    status="${inst%%|*}"
    PUBLIC_IP="${inst#*|}"
    if [[ "$status" == "Running" && -n "$PUBLIC_IP" ]]; then
        break
    fi
    log_debug "  [$(($(date +%s) - start_ts))s] status=$status ip=$PUBLIC_IP"
    sleep 5
done

# -----------------------------------------------------------------------------
# 11. ALWAYS tear down (safety net #1)
# -----------------------------------------------------------------------------
cleanup() {
    local exit_code=$?
    log_info "tearing down instance $INSTANCE_ID..."
    stop_watchdog
    aliyon ecs StopInstance --RegionId "$REGION" --InstanceId "$INSTANCE_ID" >/dev/null 2>&1 || true
    # Wait for Stopped
    wait_for_instance_status "$REGION" "$INSTANCE_ID" "Stopped" 60 || true
    aliyon ecs DeleteInstance --RegionId "$REGION" --InstanceId "$INSTANCE_ID" --Force true >/dev/null 2>&1 || {
        log_warn "DeleteInstance failed; check the Aliyun console for $INSTANCE_ID"
        return $exit_code
    }
    # Wait for it to actually disappear
    local del_deadline=$(( $(date +%s) + 60 ))
    while [[ $(date +%s) -lt $del_deadline ]]; do
        local count
        count="$(aliyon ecs DescribeInstances --RegionId "$REGION" --InstanceIds "['$INSTANCE_ID']" | jq -r '.Instances.Instance | length')"
        if [[ "$count" == "0" ]]; then break; fi
        sleep 3
    done
    return $exit_code
}
trap cleanup EXIT INT TERM

# -----------------------------------------------------------------------------
# 12. Persist infra state for aliyun-setup-base.sh / aliyun-build.sh to reuse
# -----------------------------------------------------------------------------
mkdir -p "$(dirname "$QALOS_STATE_FILE")"
cat > "$QALOS_STATE_FILE" <<EOF
{
  "region":      "$REGION",
  "zone":        "$VSW_ZONE",
  "vpcId":       "$VPC_ID",
  "vpcName":     "$VPC_NAME",
  "vswId":       "$VSW_ID",
  "vswName":     "$VSW_NAME",
  "sgId":        "$SG_ID",
  "sgName":      "$SG_NAME",
  "keyPairName": "$KP_NAME",
  "imageId":     "$IMAGE_ID",
  "updatedAt":   "$(date -u +%Y-%m-%dT%H:%M:%SZ)"
}
EOF
log_debug "state saved to $QALOS_STATE_FILE"

# -----------------------------------------------------------------------------
# 13. Report
# -----------------------------------------------------------------------------
elapsed=$(($(date +%s) - start_ts))
if [[ "$status" == "Running" ]]; then
    echo ""
    log_info "PASS"
    echo "  instance   : $INSTANCE_ID  (deleted)"
    echo "  type       : $CHOSEN_TYPE"
    echo "  image      : $IMAGE_ID"
    echo "  region/zone: $REGION / $VSW_ZONE"
    echo "  time to Running: ${elapsed}s"
    echo ""
    echo "Persistent resources KEPT (free) for aliyun-build.sh:"
    echo "  VPC      = $VPC_ID  ($VPC_NAME)"
    echo "  VSwitch  = $VSW_ID  ($VSW_NAME)  in $VSW_ZONE"
    echo "  SG       = $SG_ID  ($SG_NAME)  - SSH 22/22 from 0.0.0.0/0"
    echo "  KeyPair  = $KP_NAME"
    echo "  State    = $QALOS_STATE_FILE"
    echo ""
    echo "Cost: ~¥0.05 for this <90 s run."
    exit 0
else
    echo ""
    log_error "FAIL  final status was '$status' after ${elapsed}s"
    echo "  instance $INSTANCE_ID was deleted in the finally{}; check the Aliyun console for orphaned resources."
    exit 1
fi
