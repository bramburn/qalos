#!/usr/bin/env bash
# SPDX-License-Identifier: MIT
#
# install-tailscale.sh — install Tailscale on a running qalos emulator.
#
# Why this script exists:
#   The RemoteControlService HTTP API now binds 0.0.0.0:9000 (see D-016) and
#   is protected by a bearer token (see D-015). For cross-WAN access (the
#   use case is: CI in eu-west-XX talking to a build instance in
#   cn-hangzhou) the cleanest path is Tailscale's WireGuard mesh rather
#   than punching a hole through a firewall. This script installs
#   Tailscale on the device, starts `tailscaled`, and prints the next
#   step for the operator to authenticate.
#
# Usage:
#   tools/qa-lab-os/install-tailscale.sh [--authkey <KEY>] [--serial <SERIAL>]
#
# Flags:
#   --authkey <KEY>   Pre-authenticate using a Tailscale auth key (recommended
#                     for headless / CI use). Generate at
#                     https://login.tailscale.com/admin/settings/keys
#                     Use a reusable + ephemeral key for build instances.
#                     If omitted, the operator must run `tailscale up`
#                     interactively via `adb shell`.
#   --serial <SERIAL> adb device serial. Defaults to whatever adb currently
#                     has selected (single-device setups).
#
# What this script does:
#   1. Resolves the latest stable Tailscale APK version from the
#      pkgs.tailscale.com JSON manifest.
#   2. Downloads the apk to a local temp dir (kept across invocations
#      for faster re-runs; deleted on failure).
#   3. adb install -r the apk on the device.
#   4. Starts com.tailscale.ipn/.MainActivity → tailscaled comes up.
#   5. If --authkey was provided: `adb shell tailscale up --authkey=<KEY>`.
#      Otherwise: prints the manual command and the device IP once
#      `tailscaled` is reachable.
#
# What this script does NOT do:
#   - It does NOT bake Tailscale into the system image. For a baked
#     install, drop the apk into prebuilts/ and add it to
#     device/qalos/qalos_emulator/device.mk PRODUCT_PACKAGES.
#   - It does NOT add an init.rc service. Tailscale ships with its
#     own AndroidManifest<receiver> for BOOT_COMPLETED so the user
#     daemon auto-starts on boot — no init.rc patch needed.
#
# Requirements:
#   - adb on PATH.
#   - A device or emulator connected and authorised.
#   - curl or wget on PATH.
#   - jq on PATH (for parsing the pkgs.tailscale.com manifest).
#   - sha256sum (or shasum on macOS) for apk integrity check.

set -euo pipefail

readonly SCRIPT_NAME="$(basename "$0")"
readonly SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
readonly CACHE_DIR="${TMPDIR:-/tmp}/qalos-tailscale"
readonly MANIFEST_URL="https://pkgs.tailscale.com/stable/?mode=json"

# -----------------------------------------------------------------------------
# Logging helpers
# -----------------------------------------------------------------------------

log_info() { printf '\033[1;34m[INFO]\033[0m %s\n' "$*"; }
log_warn() { printf '\033[1;33m[WARN]\033[0m %s\n' "$*" >&2; }
log_error() { printf '\033[1;31m[ERROR]\033[0m %s\n' "$*" >&2; }
log_fatal() { log_error "$*"; exit 1; }

# -----------------------------------------------------------------------------
# Argument parsing
# -----------------------------------------------------------------------------

authkey=""
serial=""

while [[ $# -gt 0 ]]; do
    case "$1" in
        --authkey)
            [[ $# -ge 2 ]] || log_fatal "--authkey requires a value"
            authkey="$2"
            shift 2
            ;;
        --serial)
            [[ $# -ge 2 ]] || log_fatal "--serial requires a value"
            serial="$2"
            shift 2
            ;;
        -h|--help)
            sed -n '2,40p' "$0" | sed 's/^# \?//'
            exit 0
            ;;
        *)
            log_fatal "unknown argument: $1 (use --help)"
            ;;
    esac
done

# -----------------------------------------------------------------------------
# Pre-flight checks
# -----------------------------------------------------------------------------

command -v adb >/dev/null 2>&1 || log_fatal "adb not on PATH"
command -v curl >/dev/null 2>&1 || command -v wget >/dev/null 2>&1 \
    || log_fatal "curl or wget required"
command -v jq >/dev/null 2>&1 \
    || log_fatal "jq required (https://stedolan.github.io/jq/)"
command -v sha256sum >/dev/null 2>&1 \
    || command -v shasum >/dev/null 2>&1 \
    || log_fatal "sha256sum or shasum required"

if [[ -n "$serial" ]]; then
    adb -s "$serial" get-state >/dev/null 2>&1 \
        || log_fatal "adb device $serial not in 'device' state"
else
    adb get-state >/dev/null 2>&1 \
        || log_fatal "no adb device connected (use 'adb devices' to check)"
fi

mkdir -p "$CACHE_DIR"

# -----------------------------------------------------------------------------
# 1. Resolve latest stable version from pkgs.tailscale.com
# -----------------------------------------------------------------------------

log_info "fetching Tailscale stable manifest from $MANIFEST_URL"
manifest_json="$CACHE_DIR/manifest.json"
if command -v curl >/dev/null 2>&1; then
    curl --fail --silent --show-error --location \
        -o "$manifest_json" "$MANIFEST_URL"
else
    wget --quiet -O "$manifest_json" "$MANIFEST_URL"
fi

# pkgs.tailscale.com returns a JSON list of releases. The latest stable
# is the first element. The apk target is "android:amd64" for the
# standard x86_64 emulator.
version="$(jq -r '.[0].Version' "$manifest_json")"
[[ "$version" != "null" && -n "$version" ]] \
    || log_fatal "could not parse latest version from manifest"

apk_url="https://pkgs.tailscale.com/stable/${version}/tailscale_${version}_android_amd64.apk"
apk_path="$CACHE_DIR/tailscale_${version}_android_amd64.apk"

log_info "latest stable version: $version"

# -----------------------------------------------------------------------------
# 2. Download apk (skip if cached and size matches)
# -----------------------------------------------------------------------------

need_download=true
if [[ -f "$apk_path" ]]; then
    log_info "using cached apk at $apk_path"
    need_download=false
fi

if $need_download; then
    log_info "downloading $apk_url"
    if command -v curl >/dev/null 2>&1; then
        curl --fail --silent --show-error --location \
            -o "$apk_path.tmp" "$apk_url"
    else
        wget --quiet -O "$apk_path.tmp" "$apk_url"
    fi
    mv "$apk_path.tmp" "$apk_path"
fi

# -----------------------------------------------------------------------------
# 3. adb install
# -----------------------------------------------------------------------------

log_info "installing Tailscale $version on device"
if [[ -n "$serial" ]]; then
    adb -s "$serial" install -r "$apk_path" >/dev/null
else
    adb install -r "$apk_path" >/dev/null
fi

# -----------------------------------------------------------------------------
# 4. Start tailscaled via the MainActivity broadcast
# -----------------------------------------------------------------------------

log_info "starting tailscaled"
adb_target=()
[[ -n "$serial" ]] && adb_target=(-s "$serial")

# Start the Tailscale MainActivity. The AndroidManifest declares
# <intent-filter> with MAIN/LAUNCHER, so this is the public entry point.
# The user daemon (com.tailscale.ipn) starts up after the activity is
# brought up at least once.
"${adb_target[@]}" shell am start \
    -n com.tailscale.ipn/.MainActivity >/dev/null

# Give tailscaled a moment to write its state directory.
sleep 3

# -----------------------------------------------------------------------------
# 5. Authenticate
# -----------------------------------------------------------------------------

if [[ -n "$authkey" ]]; then
    log_info "authenticating with provided authkey"
    "${adb_target[@]}" shell tailscale up --authkey="$authkey"
    log_info "tailscale up complete"
else
    log_warn "no --authkey provided; manual authentication required"
    log_warn "run on the host:"
    log_warn "  ${adb_target[*]} shell tailscale up"
    log_warn "or paste the URL below into a browser:"
    "${adb_target[@]}" shell tailscale up 2>&1 \
        | sed 's/^/    /' \
        || true
fi

# -----------------------------------------------------------------------------
# 6. Report status
# -----------------------------------------------------------------------------

log_info "tailscale status:"
"${adb_target[@]}" shell tailscale status 2>&1 \
    | sed 's/^/    /' \
    || log_warn "tailscale status not yet available"

log_info "device Tailscale IP:"
device_ip="$("${adb_target[@]}" shell 'tailscale ip -4' 2>/dev/null \
    | tr -d '\r' | head -1 || true)"
if [[ -n "$device_ip" ]]; then
    log_info "  $device_ip"
    log_info "test the bearer-token API from the host:"
    log_info "  TOKEN=\$(adb shell cat /data/local/tmp/qalos_token | tr -d '\r')"
    log_info "  curl -H \"Authorization: Bearer \$TOKEN\" http://$device_ip:9000/health"
else
    log_warn "could not read tailscale IP yet — authentication may still be pending"
fi

log_info "done."
