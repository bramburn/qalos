# Building qalos on your local Linux box

This is the **main workflow** now that you have a Linux box with 16 GB+ RAM
and 200+ GB free disk. The DO on-demand pattern in `README.md` is the
fallback for clean-room CI when you don't want to disturb the local box.

## One-time setup on the Linux box

```bash
# 1. Install AOSP build dependencies (Ubuntu 22.04)
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev \
    libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip m4 bc \
    openjdk-17-jdk-headless python3 python3-pip rsync ccache jq

# 2. Install `repo` (Google's git-meta-tool)
sudo curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o /usr/local/bin/repo
sudo chmod +x /usr/local/bin/repo

# 3. Git config (repo needs it)
git config --global user.email "you@example.com"
git config --global user.name  "Your Name"

# 4. Pick a working location with ~300 GB free
mkdir -p ~/aosp
cd ~/aosp
```

## First build (one-time, slow)

```bash
cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j$(nproc) --no-tags --no-clone-bundle    # 1-2 hours the first time
../qalos/tools/apply-qalos.sh                          # copies device tree + QaLab

. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc)                                           # 1-2 hours
```

The result lands in `~/aosp/out/target/product/qalos_emulator/`. The three
images you actually want are:

- `system.img` — the qalos system image
- `boot.img` — kernel + ramdisk
- `userdata.img` — empty userdata partition (the AVD will populate it on first boot)

## Iterating on the qalos fork

```bash
# Edit the qalos sources in another terminal / VS Code remote window
# (qalos lives wherever you cloned it — typically ~/qalos)

cd ~/qalos             # or wherever you cloned the qalos manifest repo
git pull               # bring in upstream / your own commits

# Re-apply the changes to the AOSP working tree
cd ~/aosp
../qalos/tools/apply-qalos.sh

# Rebuild only what changed
. build/envsetup.sh
m -j$(nproc) QaLab               # rebuild just the QaLab app
# or
m -j$(nproc)                     # rebuild everything
```

The `apply-qalos.sh` script is idempotent — re-running it after a `git pull`
refreshes the working tree.

## Running the AVD on the box

```bash
cd ~/aosp
. build/envsetup.sh
lunch qalos_emulator-userdebug

# The emulator binary is at prebuilts/android-emulator/<arch>/emulator
# A minimal launch:
$ANDROID_PRODUCT_OUT/../../prebuilts/android-emulator/linux-x86_64/emulator \
    -sysdir $ANDROID_PRODUCT_OUT \
    -system $ANDROID_PRODUCT_OUT/system.img \
    -ramdisk $ANDROID_PRODUCT_OUT/ramdisk.img \
    -data $ANDROID_PRODUCT_OUT/userdata.img \
    -no-window -no-audio -no-snapshot -gpu swiftshader_indirect &

# Once booted, adb works locally
adb wait-for-device
adb shell am start -n com.qalab/.QaLabActivity
```

(If you're SSHed in from Windows, the `-no-window` flag means you can only
interact via adb. To see the AVD's screen, run with `-window` and either an
X11-forwarded display or a VNC server on the Linux box.)

## When to use the DO / GH Actions fallback

The fallback pattern (in `tools/doctl-build.ps1`, `tools/doctl-avd.ps1`, and
`.github/workflows/build.yml`) is for when you want a build that proves
nothing on this box is influencing the result — useful for:

- A real clean-room CI signal
- A build you can hand to a colleague for repro
- Reproducing a bug that might be specific to this box's state

The scripts stay in the repo and stay maintained; you just don't run them
day-to-day.

## Housekeeping

- `ccache` keeps build caches in `~/.ccache` — clear it (`ccache -C`) if you
  hit weird stale-build bugs.
- `~/aosp/out/` is the build output. It can be deleted to free disk; the
  next build will be a from-scratch rebuild (slow).
- AOSP source tree is ~80-100 GB. The build output is ~50-100 GB. ccache is
  up to 20 GB. Total working set: ~150-220 GB.
