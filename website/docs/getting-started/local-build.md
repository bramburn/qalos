---
sidebar_position: 2
---

# Local build

The primary build path. 1-4 hours on a modern Linux box, $0 marginal cost, no rate limits.

## Prerequisites

- **OS:** Ubuntu 22.04+ (or any Debian-derived distro with the same packages)
- **RAM:** 16 GB minimum, 32 GB recommended. AOSP's Soong phase consumes 30+ GB on its own.
- **Disk:** 200 GB free minimum. 500 GB if you plan to keep multiple build outputs.
- **CPU:** 8+ cores. AOSP's parallel compilation is CPU-bound.

## One-time setup

```bash
sudo apt-get install -y --no-install-recommends \
    git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev \
    libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip m4 bc \
    openjdk-17-jdk-headless python3 python3-pip rsync ccache jq
sudo curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o /usr/local/bin/repo && sudo chmod +x /usr/local/bin/repo
git config --global user.email "you@example.com" && git config --global user.name "Your Name"
```

## First build

```bash
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j$(nproc) --no-tags --no-clone-bundle    # 1-2 hours, first time
../qalos/tools/apply-qalos.sh                          # copies qalos product files into the tree
. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc)                                           # 1-2 hours, first time
```

The three images you want land in `~/aosp/out/target/product/qalos_emulator/`:

- `system.img` — the system partition
- `boot.img` — the kernel + ramdisk
- `userdata.img` — initial user data partition

## Iterating

```bash
# after editing QaLab code:
cd ~/aosp
. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc) qalos_target                # only rebuild the qalos bits
```

## Booting the result in an emulator

```bash
emulator -avd qalos-test -no-snapshot -wipe-data \
    -sysdir ~/aosp/out/target/product/qalos_emulator/ \
    -system system.img -ramdisk ramdisk.img -userdata userdata.img \
    -kernel kernel
```

Or use `avdmanager` to create a proper AVD and point it at the image. See the [AOSP emulator docs](https://source.android.com/docs/setup/start/run-avd) for the full walkthrough.

## Cleaning up

```bash
# nuke a single build output (keeps the source tree)
rm -rf ~/aosp/out

# nuke the whole AOSP source tree (start over)
rm -rf ~/aosp
```

## Memory-saving: `ccache`

`ccache` is installed by the package list above. It caches compiled objects across builds, so a no-op rebuild takes seconds instead of hours.

```bash
# set the cache size (50 GB is reasonable for a single AOSP project)
ccache -M 50G

# check the hit rate
ccache -s
```

## What's next

- Want to share a build? → [DO build](do-build) or [Aliyun build](aliyun-build)
- Want to add a feature? → [How to contribute](../contributing/how-to-contribute)
- Hit a build error? → check the [Troubleshooting](https://source.android.com/docs/setup/build/building#troubleshooting) page in the AOSP docs first, then open an issue if the bug is in qalos.
