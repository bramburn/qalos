#!/usr/bin/env bash
# qalos — one-time base-droplet setup.
#
# Run this once on a fresh Ubuntu 22.04 DigitalOcean droplet to install every
# dependency the AOSP build needs. After this finishes, snapshot the droplet —
# that snapshot becomes the `qalos-build-warm` golden image used by every
# subsequent on-demand build.
#
# Usage (on the droplet, as root):
#     curl -sSL https://raw.githubusercontent.com/bramburn/qalos/main/tools/setup-droplet.sh | bash
#   or, after cloning the qalos repo:
#     ./tools/setup-droplet.sh
#
# What it installs:
#   - AOSP build deps (gcc, g++, make, JDK 17, Python 3, flex, bison, etc.)
#   - repo (Google's git-meta-tool)
#   - s3cmd + ca-certificates (for uploading built images to DO Spaces)
#   - ccache (for faster incremental builds)
#
# What it does NOT do:
#   - run `repo sync` (that's part of the build step; you don't want to bake
#     80 GB of AOSP source into the snapshot unless you're happy paying for
#     the snapshot storage every month)

set -euo pipefail

if [ "$(id -u)" -ne 0 ]; then
    echo "[qalos-setup] must run as root" >&2
    exit 1
fi

echo "[qalos-setup] starting at $(date -u +%Y-%m-%dT%H:%M:%SZ)"

export DEBIAN_FRONTEND=noninteractive

apt-get update
apt-get install -y --no-install-recommends \
    ca-certificates \
    curl \
    git \
    gnupg \
    flex \
    bison \
    gperf \
    build-essential \
    zip \
    zlib1g-dev \
    gcc-multilib \
    g++-multilib \
    libc6-dev-i386 \
    lib32ncurses5-dev \
    lib32z1-dev \
    x11proto-core-dev \
    libx11-dev \
    libgl1-mesa-dev \
    libxml2-utils \
    liblz4-tool \
    libssl-dev \
    xsltproc \
    unzip \
    m4 \
    bc \
    openjdk-17-jdk-headless \
    python3 \
    python3-pip \
    rsync \
    ccache \
    s3cmd \
    jq

# `repo` — Google's git-meta-tool for AOSP.
curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo > /usr/local/bin/repo
chmod +x /usr/local/bin/repo

# Git config (required for repo to operate).
git config --global user.email "qalos@qalab.local"
git config --global user.name  "qalos build"
git config --global color.ui  true

# Shrink the snapshot — apt cache is the biggest easy win.
apt-get clean
rm -rf /var/lib/apt/lists/*

echo "[qalos-setup] done at $(date -u +%Y-%m-%dT%H:%M:%SZ)"
echo "[qalos-setup] next: snapshot this droplet from the DO control panel, name it 'qalos-build-warm'."
