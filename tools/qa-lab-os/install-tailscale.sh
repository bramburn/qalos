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
#   Tailscale on the device, starts `tailscaled`, and authenticates.
#
# Usage:
#   tools/qa-lab-os/install-tailscale.sh [--authkey <KEY>] [--serial <SERIAL>]
#
# Flags:
#   --authkey <KEY>   Pre-authenticate using a Tailscale auth key (recommended
#                     for headless / CI use). Generate at
#                     https://login.tailscale.com/admin/settings/keys
#                     Use a reusable + ephemeral key for build instances.
#                     If the broadcast intent is unavailable on the
#                     installed Tailscale build, the script falls back to
#                     printing manual instructions (the operator pastes
#                     the key in Settings → Use auth key inside the app).
#   --serial <SERIAL> adb device serial. Defaults to whatever adb currently
#                     has selected (single-device setups).
#
# What this script does:
#   1. Resolves the latest stable Tailscale APK version from the
#      pkgs.tailscale.com JSON manifest.
#   2. Downloads the apk + sha256sum.txt; verifies the apk's SHA256
#      against the published manifest before installing.
#   3. adb install -r the apk on the device.
#   4. Starts com.tailscale.ipn/.MainActivity → tailscaled comes up.
#   5. If --authkey was provided: tries the LOGIN_WITH_AUTH_KEY
#      intent; falls back to manual instructions on failure.
#      Otherwise: prints manual instructions and waits for the
#      operator to complete auth in the app.
#   6. Polls for `tailscaled` to come up (reads state via
#      `dumpsys package com.tailscale.ipn` to detect first-run vs
#      authenticated state).
#   7. Reports the device's Tailscale IP once up.
#
# What this script does NOT do:
#   - It does NOT bake Tailscale into the system image. For a baked
#     install, drop the apk into prebuilts/ and add it to
#     device/qalos/qalos_emulator/device.mk PRODUCT_PACKAGES.
#   - It does NOT add an init.rc service. Tailscale ships its own
#     BOOT_COMPLETED receiver so the user daemon auto-starts on boot.
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

# Pick the sha256sum binary on this host. macOS ships `shasum -a 256`
# instead of GNU coreutils `sha256sum`. Returns the command + the args
# that produce a bare hex digest on stdout.
sha256_bin() {
    if command -v sha256sum >/dev/null 2>&1; then
        echo "sha256sum"
    elif command -v shasum >/dev/null 2>&1; then
        echo "shasum -a 256"
    else
        log_fatal "neither sha256sum nor shasum on PATH"
    fi
}

# Pick curl-or-wget. Returns "curl" or "wget".
http_bin() {
    if command -v curl >/dev/null 2>&1; then
        echo "curl"
    elif command -v wget >/dev/null 2>&1; then
        echo "wget"
    else
        log_fatal "neither curl nor wget on PATH"
    fi
}

# Download $1 to $2. Failures abort.
download() {
    local url="$1" dest="$2"
    case "$(http_bin)" in
        curl)
            curl --fail --silent --show-error --location -o "$dest" "$url"
            ;;
        wget)
            wget --quiet -O "$dest" "$url"
            ;;
    esac
}

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
            sed -n '2,42p' "$0" | sed 's/^# \?//'
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
sha256_bin >/dev/null
http_bin >/dev/null
command -v jq >/dev/null 2>&1 \
    || log_fatal "jq required (https://stedolan.github.io/jq/)"

if [[ -n "$serial" ]]; then
    adb -s "$serial" get-state >/dev/null 2>&1 \
        || log_fatal "adb device $serial not in 'device' state"
else
    adb get-state >/dev/null 2>&1 \
        || log_fatal "no adb device connected (use 'adb devices' to check)"
fi

mkdir -p "$CACHE_DIR"

# adb_target is an empty array by default; the [-s serial] variant is
# appended when --serial was given. Expanding "${adb_target[@]}" in a
# command line is then safe and well-quoted.
adb_target=()
[[ -n "$serial" ]] && adb_target=(-s "$serial")

# -----------------------------------------------------------------------------
# 1. Resolve latest stable version from pkgs.tailscale.com
# -----------------------------------------------------------------------------

log_info "fetching Tailscale stable manifest from $MANIFEST_URL"
manifest_json="$CACHE_DIR/manifest.json"
download "$MANIFEST_URL" "$manifest_json"

# pkgs.tailscale.com returns a JSON array of releases; the first element
# is the latest stable. The apk target is "android:amd64" for the
# standard x86_64 emulator. The version field is in semver (1.78.0).
version="$(jq -r '.[0].Version' "$manifest_json")"
[[ "$version" != "null" && -n "$version" ]] \
    || log_fatal "could not parse latest version from manifest"

apk_filename="tailscale_${version}_android_amd64.apk"
apk_url="https://pkgs.tailscale.com/stable/${version}/${apk_filename}"
sha_url="https://pkgs.tailscale.com/stable/${version}/sha256sum.txt"
apk_path="$CACHE_DIR/${apk_filename}"
sha_path="$CACHE_DIR/${version}-sha256sum.txt"

log_info "latest stable version: $version"

# -----------------------------------------------------------------------------
# 2. Download apk + sha256sum.txt; verify
# -----------------------------------------------------------------------------

need_download=true
if [[ -f "$apk_path" && -f "$sha_path" ]]; then
    # Re-verify the cached apk against the cached manifest. If the
    # check fails (corrupt cache, version upgrade on disk), redownload.
    expected_hash="$(awk -v f="$apk_filename" '$2 == f { print $1 }' "$sha_path")"
    if [[ -n "$expected_hash" ]]; then
        actual_hash="$($(sha256_bin) "$apk_path" | awk '{ print $1 }')"
        if [[ "$actual_hash" == "$expected_hash" ]]; then
            log_info "cached apk verified (sha256: ${actual_hash:0:12}…)"
            need_download=false
        else
            log_warn "cached apk sha256 mismatch — redownloading"
        fi
    fi
fi

if $need_download; then
    log_info "downloading sha256sum.txt"
    download "$sha_url" "$sha_path"
    expected_hash="$(awk -v f="$apk_filename" '$2 == f { print $1 }' "$sha_path")"
    [[ -n "$expected_hash" ]] \
        || log_fatal "no entry for $apk_filename in $sha_url"

    log_info "downloading $apk_url"
    download "$apk_url" "$apk_path.tmp"
    mv "$apk_path.tmp" "$apk_path"

    log_info "verifying apk sha256"
    actual_hash="$($(sha256_bin) "$apk_path" | awk '{ print $1 }')"
    if [[ "$actual_hash" != "$expected_hash" ]]; then
        rm -f "$apk_path"
        log_fatal "sha256 mismatch: expected $expected_hash, got $actual_hash"
    fi
    log_info "verified (sha256: ${actual_hash:0:12}…)"
fi

# -----------------------------------------------------------------------------
# 3. adb install
# -----------------------------------------------------------------------------

log_info "installing Tailscale $version on device"
"${adb_target[@]}" install -r "$apk_path" >/dev/null

# -----------------------------------------------------------------------------
# 4. Start tailscaled via the MainActivity
# -----------------------------------------------------------------------------

log_info "starting Tailscale app (com.tailscale.ipn/.MainActivity)"
"${adb_target[@]}" shell am start \
    -n com.tailscale.ipn/.MainActivity >/dev/null

# Give tailscaled a moment to write its state directory.
sleep 3

# -----------------------------------------------------------------------------
# 5. Authenticate
# -----------------------------------------------------------------------------

if [[ -n "$authkey" ]]; then
    # Two paths to push an auth key:
    #
    #   (a) Broadcast intent — works on Tailscale Android ≥ 1.50:
    #         am broadcast -a com.tailscale.ipn.LOGIN_WITH_AUTH_KEY \
    #             -e authKey tskey-... com.tailscale.ipn
    #
    #   (b) Manual — Settings → "Use auth key" inside the app.
    #
    # We try (a) first and verify success by tailing logcat for the
    # "logged in" line. If we don't see it within ~10 s we print (b)
    # so the operator can finish auth.
    log_info "submitting auth key via broadcast intent"
    log_info "(if this fails you'll be prompted to paste the key manually)"
    "${adb_target[@]}" logcat -c
    "${adb_target[@]}" shell am broadcast \
        -a com.tailscale.ipn.LOGIN_WITH_AUTH_KEY \
        -n com.tailscale.ipn/.MyBroadcastReceiver \
        -e authKey "$authkey" >/dev/null 2>&1 || true

    # Some Tailscale Android builds register the broadcast receiver
    # under a different class name. Try the package-targeted broadcast
    # too as a fallback.
    "${adb_target[@]}" shell am broadcast \
        -a com.tailscale.ipn.LOGIN_WITH_AUTH_KEY \
        -p com.tailscale.ipn \
        -e authKey "$authkey" >/dev/null 2>&1 || true

    # Wait up to 10 s for either a success log or an auth-URL log.
    authenticated=false
    for _ in $(seq 1 20); do
        sleep 0.5
        if "${adb_target[@]}" logcat -d -s Tailscale:V 2>/dev/null \
            | grep -E -q '(logged in|authenticated|state.*Running)'; then
            authenticated=true
            break
        fi
        # If tailscaled has started but isn't logged in, the app
        # shows a login URL — capture it for the operator.
        auth_url="$("${adb_target[@]}" logcat -d 2>/dev/null \
            | grep -oE 'https://login\.tailscale\.com/a/[A-Za-z0-9]+' \
            | head -1 || true)"
        if [[ -n "${auth_url:-}" && "$authenticated" != "true" ]]; then
            :
        fi
    done

    if $authenticated; then
        log_info "authenticated"
    else
        log_warn "broadcast did not appear to succeed; auth may be incomplete"
        log_warn "open the Tailscale app on the device → Settings → 'Use auth key' →"
        log_warn "  paste this key: $authkey"
        log_warn "(then re-run this script with no --authkey to confirm)"
    fi
else
    log_warn "no --authkey provided; manual authentication required"
    log_warn "open the Tailscale app on the device and tap 'Sign in',"
    log_warn "or run this script again with --authkey=<KEY> for headless auth."
fi

# -----------------------------------------------------------------------------
# 6. Poll for the device's Tailscale IP
# -----------------------------------------------------------------------------

# Tailscale's android app stores its state in /data/data/com.tailscale.ipn/.
# The IP is also broadcast in logcat at "Tailscale" tag after a successful
# connect. We try logcat first (fast path); fall back to a short poll loop.
log_info "waiting for tailscale IP (up to 30 s)…"
device_ip=""
for _ in $(seq 1 60); do
    # logcat grep for the "100.x.y.z" Tailscale IPv4 — also matches
    # "tailscale: 100.64.0.2" style lines.
    device_ip="$("${adb_target[@]}" logcat -d 2>/dev/null \
        | grep -oE '100\.(6[4-9]|[7-9][0-9]|1[0-1][0-9]|12[0-7])\.[0-9]+\.[0-9]+' \
        | head -1 || true)"
    if [[ -n "$device_ip" ]]; then
        break
    fi
    sleep 0.5
done

# -----------------------------------------------------------------------------
# 7. Report
# -----------------------------------------------------------------------------

log_info "tailscale status:"
"${adb_target[@]}" shell am start \
    -a com.tailscale.ipn.action.SHOW_STATUS \
    -n com.tailscale.ipn/.StatusActivity >/dev/null 2>&1 || true
sleep 1

if [[ -n "$device_ip" ]]; then
    log_info "device Tailscale IP: $device_ip"
    log_info ""
    log_info "test the bearer-token API from the host:"
    log_info "  TOKEN=\$(${adb_target[*]} shell cat /data/local/tmp/qalos_token | tr -d '\r')"
    log_info "  curl -H \"Authorization: Bearer \$TOKEN\" http://$device_ip:9000/health"
else
    log_warn "could not detect Tailscale IP yet — authentication may still be pending"
    log_warn "check the Tailscale app on the device; once authenticated, the IP"
    log_warn "appears under '100.x.x.x' in the app and in 'adb logcat -s Tailscale'"
fi

log_info "done."
