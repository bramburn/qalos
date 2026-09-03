#!/usr/bin/env bash
#
# scripts/aliyun-install.sh - install the Aliyun CLI on macOS / Linux.
#
# Mirrors tools/aliyun-install.ps1 for the Windows path. Idempotent.
# Drops the binary in ~/.local/bin/aliyun (or /usr/local/bin/aliyun if
# run with sudo). Adds the install dir to the user's PATH via the
# shell's profile file.
#
# Auth: after this script finishes, run `aliyun configure` once to provide
# an AccessKey ID + Secret + default region. The default profile is what
# the other tools/* and scripts/* read.
#
# Usage:
#   ./scripts/aliyun-install.sh                  # installs to ~/.local/bin
#   sudo ./scripts/aliyun-install.sh --system    # installs to /usr/local/bin

set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Args
INSTALL_SYSTEM=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --system) INSTALL_SYSTEM=1; shift ;;
        -h|--help)
            cat <<'EOF'
Usage: aliyun-install.sh [--system]

  (default)  Install to ~/.local/bin/aliyun and add to user PATH
  --system   Install to /usr/local/bin/aliyun (requires sudo)
EOF
            exit 0
            ;;
        *) echo "Unknown option: $1" >&2; exit 1 ;;
    esac
done

# Pick the install dir
if [[ "$INSTALL_SYSTEM" -eq 1 ]]; then
    INSTALL_DIR="/usr/local/bin"
    if [[ "$EUID" -ne 0 ]]; then
        echo "ERROR: --system requires root. Re-run with sudo." >&2
        exit 1
    fi
else
    INSTALL_DIR="$HOME/.local/bin"
    mkdir -p "$INSTALL_DIR"
fi

# Already installed? Print version and exit.
if [[ -x "$INSTALL_DIR/aliyun" ]]; then
    echo "aliyun already installed: $("$INSTALL_DIR/aliyun" version | head -1) at $INSTALL_DIR/aliyun"
    exit 0
fi

# Pick the right tarball for this OS/arch
OS="$(uname -s | tr '[:upper:]' '[:lower:]')"
ARCH="$(uname -m)"
case "$OS" in
    linux)  url="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-amd64.tgz" ;;
    darwin) url="https://aliyuncli.alicdn.com/aliyun-cli-macosx-latest-universal.tgz" ;;
    *) echo "ERROR: unsupported OS: $OS" >&2; exit 1 ;;
esac
case "$ARCH" in
    x86_64|amd64) : ;;  # ok
    arm64|aarch64)
        if [[ "$OS" == "linux" ]]; then
            url="https://aliyuncli.alicdn.com/aliyun-cli-linux-latest-arm64.tgz"
        fi
        ;;
    *) echo "ERROR: unsupported arch: $ARCH" >&2; exit 1 ;;
esac

tmpdir="$(mktemp -d)"
trap 'rm -rf "$tmpdir"' EXIT

echo "Downloading $url ..."
curl -fsSL "$url" -o "$tmpdir/aliyun.tgz"
tar -xzf "$tmpdir/aliyun.tgz" -C "$tmpdir"
install -m 0755 "$tmpdir/aliyun" "$INSTALL_DIR/aliyun"

# Add to PATH for future shells (only when installing to user dir)
if [[ "$INSTALL_SYSTEM" -eq 0 ]]; then
    shell_name="$(basename "${SHELL:-/bin/bash}")"
    profile=""
    case "$shell_name" in
        bash) profile="$HOME/.bashrc" ;;
        zsh)  profile="$HOME/.zshrc" ;;
        *)    profile="$HOME/.profile" ;;
    esac
    if [[ -f "$profile" ]] && ! grep -q '\.local/bin' "$profile" 2>/dev/null; then
        echo "" >> "$profile"
        echo "# Added by qalos aliyun-install.sh on $(date +%Y-%m-%d)" >> "$profile"
        echo "export PATH=\"\$HOME/.local/bin:\$PATH\"" >> "$profile"
        echo "Added ~/.local/bin to PATH in $profile. New shells will pick it up."
    fi
    # Also export for the current session
    export PATH="$HOME/.local/bin:$PATH"
fi

echo ""
"$INSTALL_DIR/aliyun" version | head -2
echo ""
echo "aliyun is ready."
echo ""
echo "Next: configure credentials with 'aliyun configure' (one-time, interactive)."
echo "You'll need an Alibaba Cloud AccessKey ID and Secret. Recommended: create a"
echo "dedicated RAM user with AliyunECSFullAccess + AliyunVPCFullAccess, NOT the root"
echo "account key. See https://ram.console.aliyun.com/users for RAM user setup."
echo ""
echo "After configuring, run scripts/aliyun-smoke-test.sh to prove end-to-end works."
