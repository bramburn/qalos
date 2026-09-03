# scripts/lib/aliyun-common.sh - shared helpers for the Aliyun orchestrators
#
# Sourced by the aliyun-*.sh scripts. Not for direct execution.
#
# Provides:
#   aliyon       - run aliyun with JSON parsing, transient retry
#   get_state    - read .pi/aliyun-state.json
#   save_state   - write .pi/aliyun-state.json
#   require_aliyun, require_jq, require_ssh
#   with_watchdog- run a child process that force-deletes the instance on parent death
#   wait_for_instance_status
#   smallest_in_stock_instance_type

# Only define once even if sourced multiple times.
if [[ -n "${__QALOS_ALIYUN_COMMON_SH_LOADED:-}" ]]; then
    return 0
fi
__QALOS_ALIYUN_COMMON_SH_LOADED=1

# Source the log helpers (relative to this file's directory).
_LIB_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
# shellcheck source=./log.sh
source "$_LIB_DIR/log.sh"

# ---------------------------------------------------------------------------
# Prereq checks
# ---------------------------------------------------------------------------

# Locate the aliyun binary. Default: PATH. Override via QALOS_ALIYUN env.
QALOS_ALIYUN="${QALOS_ALIYUN:-aliyun}"

require_aliyun() {
    if ! command -v "$QALOS_ALIYUN" >/dev/null 2>&1; then
        log_fatal "aliyun CLI not found on PATH (looked for: $QALOS_ALIYUN). Run scripts/aliyun-install.sh or set QALOS_ALIYUN=/path/to/aliyun."
    fi
}

require_jq() {
    if ! command -v jq >/dev/null 2>&1; then
        log_fatal "jq not found. Install it: brew install jq  /  sudo apt-get install -y jq"
    fi
}

require_ssh() {
    if ! command -v ssh >/dev/null 2>&1; then
        log_fatal "ssh not found. Install OpenSSH client."
    fi
}

# ---------------------------------------------------------------------------
# aliyon - run aliyun, parse JSON, retry transient errors
#
# Mirrors the Invoke-AliyunJson PowerShell helper.
#
# Usage: aliyon <subcommand> [args...]
# Echoes the parsed JSON object on stdout. Returns 0 on success, non-zero on
# permanent failure.
# ---------------------------------------------------------------------------
aliyon() {
    local max_attempts="${ALIYON_MAX_ATTEMPTS:-4}"
    local backoff="${ALIYON_BACKOFF_SECONDS:-3}"
    local attempt=0
    while [[ $attempt -lt $max_attempts ]]; do
        attempt=$((attempt + 1))
        local out
        out="$("$QALOS_ALIYUN" "$@" 2>&1)" || true
        # Extract the first JSON object from the output (the aliyun CLI
        # sometimes prints license banners or warnings on stderr that get
        # mixed into stdout in 2>&1).
        local json
        json="$(printf '%s' "$out" | grep -m1 -oE '\{.*\}' || true)"
        if [[ -n "$json" ]]; then
            if printf '%s' "$json" | jq . >/dev/null 2>&1; then
                printf '%s' "$json"
                return 0
            fi
        fi
        # Detect transient errors worth retrying
        if [[ "$out" =~ SDK\.ServerError|Throttling|ServiceUnavailable|InternalError ]]; then
            if [[ $attempt -lt $max_attempts ]]; then
                log_warn "  (transient error, retry $attempt/$max_attempts in ${backoff}s)"
                sleep "$backoff"
                continue
            fi
        fi
        # Non-transient or out of retries - surface the error
        log_error "  [aliyun $* failed]"
        printf '%s\n' "$out" | grep -E 'ERROR|error|code' | head -4 | sed 's/^/    /' >&2
        return 1
    done
    return 1
}

# ---------------------------------------------------------------------------
# State file (.pi/aliyun-state.json) - the Aliyun infra IDs
# ---------------------------------------------------------------------------

# Default: $REPO_ROOT/.pi/aliyun-state.json
QALOS_REPO_ROOT="${QALOS_REPO_ROOT:-$(cd "$_LIB_DIR/../.." && pwd)}"
QALOS_STATE_FILE="${QALOS_STATE_FILE:-$QALOS_REPO_ROOT/.pi/aliyun-state.json}"

get_state() {
    if [[ -f "$QALOS_STATE_FILE" ]]; then
        jq . "$QALOS_STATE_FILE"
    else
        return 1
    fi
}

save_state() {
    # Args: key=value pairs to write
    local tmp
    tmp="$(mktemp)"
    # Start with existing state (or empty object), then merge in
    if [[ -f "$QALOS_STATE_FILE" ]]; then
        jq . "$QALOS_STATE_FILE" > "$tmp" 2>/dev/null || echo '{}' > "$tmp"
    else
        echo '{}' > "$tmp"
    fi
    for kv in "$@"; do
        local k="${kv%%=*}"
        local v="${kv#*=}"
        # Use jq to set the field (handles strings, numbers, booleans uniformly
        # as strings; that's fine for our state shape).
        local updated
        updated="$(jq --arg k "$k" --arg v "$v" --arg ts "$(date -u +%Y-%m-%dT%H:%M:%SZ)" \
            '. + {($k): $v, updatedAt: $ts}' "$tmp")"
        printf '%s' "$updated" > "$tmp"
    done
    mkdir -p "$(dirname "$QALOS_STATE_FILE")"
    mv "$tmp" "$QALOS_STATE_FILE"
    log_debug "state saved to $QALOS_STATE_FILE"
}

# ---------------------------------------------------------------------------
# Wait for an ECS instance to reach a target status
# ---------------------------------------------------------------------------

# Args: region, instance_id, target_status, max_wait_seconds
wait_for_instance_status() {
    local region="$1" instance_id="$2" target_status="$3" max_wait="${4:-300}"
    local deadline=$(( $(date +%s) + max_wait ))
    while [[ $(date +%s) -lt $deadline ]]; do
        local status
        status="$(aliyon ecs DescribeInstances --RegionId "$region" --InstanceIds "['$instance_id']" \
            | jq -r '.Instances.Instance[0].Status // empty' 2>/dev/null || true)"
        if [[ "$status" == "$target_status" ]]; then
            return 0
        fi
        log_debug "  status=$status (waiting for $target_status)"
        sleep 5
    done
    log_error "  timed out waiting for $instance_id to reach $target_status after ${max_wait}s"
    return 1
}

# ---------------------------------------------------------------------------
# Smallest in-stock instance type in a region/zone
#
# Mirrors the PowerShell logic in aliyun-smoke-test.ps1.
# ---------------------------------------------------------------------------

# Args: region, zone  - echoes the chosen instance type id
smallest_in_stock_instance_type() {
    local region="$1" zone="$2"
    # Get the full in-stock list. The --InstanceType filter on this API is
    # unreliable, so we filter in shell.
    local in_stock_json
    in_stock_json="$(aliyun ecs DescribeAvailableResource \
        --RegionId "$region" --ZoneId "$zone" --DestinationResource 'InstanceType' \
        | jq -r '.AvailableZones.AvailableZone.AvailableResources.AvailableResource[]
                | .SupportedResources.SupportedResource[]
                | select(.Status == "Available") | .Value')"
    if [[ -z "$in_stock_json" ]]; then
        log_fatal "no instance types in stock in $region/$zone"
    fi
    # Look up specs for each in-stock type
    local in_stock_array=()
    while IFS= read -r line; do
        in_stock_array+=("$line")
    done <<< "$in_stock_json"
    # Query specs in a single DescribeInstanceTypes call
    local types_json
    types_json="$(printf '%s\n' "${in_stock_array[@]}" | jq -R . | jq -s . | jq -c '.')"
    local specs_json
    specs_json="$(aliyun ecs DescribeInstanceTypes \
        --InstanceTypes "$types_json" 2>/dev/null \
        | jq -r '.InstanceTypes.InstanceType[] | [.InstanceTypeId, .CpuCoreCount, .MemorySize, .InstanceTypeFamily] | @tsv')"
    # Pick smallest by RAM, then vCPU, excluding exotic families
    local chosen
    chosen="$(printf '%s\n' "$specs_json" \
        | grep -v -E 'ecs\.(poc-test|ebm[a-z]?|gn|sgn|gn8|vfx)' \
        | sort -t$'\t' -k3,3n -k2,2n \
        | head -1 \
        | cut -f1)"
    if [[ -z "$chosen" ]]; then
        log_fatal "no suitable in-stock instance type in $region/$zone after filtering exotic families"
    fi
    printf '%s' "$chosen"
}

# ---------------------------------------------------------------------------
# Background watchdog: force-delete the instance if the parent dies
#
# Spawns a child process that polls the parent PID. When the parent is gone,
# it stop+delete's the instance and exits.
#
# Usage: with_watchdog <region> <instance_id>
#   Sets a global $WATCHDOG_PID you can later kill to stop the watchdog.
# ---------------------------------------------------------------------------

with_watchdog() {
    local region="$1" instance_id="$2"
    (
        parent_pid=$$
        while true; do
            sleep 5
            if ! kill -0 "$parent_pid" 2>/dev/null; then
                "$QALOS_ALIYUN" ecs StopInstance --RegionId "$region" --InstanceId "$instance_id" 2>/dev/null || true
                sleep 5
                "$QALOS_ALIYUN" ecs DeleteInstance --RegionId "$region" --InstanceId "$instance_id" --Force true 2>/dev/null || true
                exit 0
            fi
        done
    ) &
    WATCHDOG_PID=$!
    log_debug "watchdog started (pid $WATCHDOG_PID, watching $instance_id)"
}

stop_watchdog() {
    if [[ -n "${WATCHDOG_PID:-}" ]] && kill -0 "$WATCHDOG_PID" 2>/dev/null; then
        kill "$WATCHDOG_PID" 2>/dev/null || true
        wait "$WATCHDOG_PID" 2>/dev/null || true
    fi
}

# Ensure the watchdog is stopped on any exit
trap stop_watchdog EXIT INT TERM
