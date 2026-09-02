# qalos first build — CLI agent brief

**Goal**: build the qalos Android emulator system image on this Ubuntu box
and report back with success/failure and the location of the built images.

**Time estimate**: 2–4 hours total. Most of it is `repo sync` (1–2 hours the
first time) and the AOSP build (1–2 hours). Stay in the session until done —
AOSP builds cannot be safely interrupted at the link stage.

**Disk estimate**: ~150–200 GB used (80 GB source + 100–150 GB build
output). Verify you have at least 250 GB free before starting.

---

## Pre-flight checks (run all of these first, abort if any fail)

```bash
# Confirm OS (Ubuntu 22.04+)
. /etc/os-release
[ "$ID" = "ubuntu" ] && [ "${VERSION_ID%%.*}" -ge 22 ] \
  || { echo "FAIL: need Ubuntu 22.04+, have $ID $VERSION_ID"; exit 1; }

# Confirm RAM (16 GB recommended; 14 GB minimum; 8 GB will likely OOM)
total_mem_gb=$(awk '/MemTotal/ {print int($2/1024/1024)}' /proc/meminfo)
[ "$total_mem_gb" -ge 14 ] \
  || { echo "FAIL: need at least 14 GB RAM, have $total_mem_gb GB"; exit 1; }

# Confirm free disk on $HOME (250 GB minimum)
free_gb=$(df -BG --output=avail "$HOME" | tail -1 | tr -dc '0-9')
[ "$free_gb" -ge 250 ] \
  || { echo "FAIL: need at least 250 GB free on $HOME, have ${free_gb}GB"; exit 1; }

echo "OK: $(nproc) CPUs, ${total_mem_gb} GB RAM, ${free_gb} GB free on $HOME"
```

If you have `sudo` access without a password, prefix the `apt-get` and
`curl ... /usr/local/bin/...` commands below with `sudo`. If you don't, run
the session as root or `sudo -i` first.

---

## Step 1 — Install AOSP build dependencies (5–10 min)

```bash
sudo apt-get update
sudo apt-get install -y --no-install-recommends \
    git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev \
    libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip m4 bc \
    openjdk-17-jdk-headless python3 python3-pip rsync ccache jq
```

If `openjdk-17-jdk-headless` is not in the repos, you may need to enable
universe first: `sudo add-apt-repository universe && sudo apt-get update`.

---

## Step 2 — Install `repo` (Google's git-meta-tool)

```bash
sudo curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o /usr/local/bin/repo
sudo chmod +x /usr/local/bin/repo
repo --version
```

If the curl fails, the box may be behind a firewall that blocks
`storage.googleapis.com`. Test with `curl -fsSI
https://storage.googleapis.com/git-repo-downloads/repo`.

---

## Step 3 — Git config (required by `repo`)

```bash
git config --global user.email "qalos-build@qalab.local"
git config --global user.name  "qalos build"
```

---

## Step 4 — Clone the qalos manifest (1 min)

```bash
mkdir -p ~/qalos
cd ~/qalos
git clone https://github.com/bramburn/qalos.git .
```

If the clone fails, test the network: `curl -fsSI https://github.com/bramburn/qalos`.
A failure here means the box can't reach GitHub — sort that out before
continuing.

---

## Step 5 — Initialize `repo` (1 min)

```bash
mkdir -p ~/aosp
cd ~/aosp
repo init -u ~/qalos -b main
```

Expected tail of output: `repo has been initialized in <path>`.

If this fails with "no default revision", the manifest clone in step 4 is
broken. Re-run step 4.

---

## Step 6 — Sync AOSP source (1–2 hours the first time)

```bash
cd ~/aosp
repo sync -c -j$(nproc) --no-tags --no-clone-bundle 2>&1 | tee ~/qalos/.repo-sync.log
```

This downloads ~80 GB. Let it run. The `tee` keeps a log in `~/qalos/`.

To monitor in another shell: `tail -f ~/qalos/.repo-sync.log`.

**Resumable**: if the connection drops, just re-run the same command.
`repo sync` continues from where it left off.

If a specific project fails 3 times in a row, report the project name and
the error message — that's a real issue, not a transient network blip.

---

## Step 7 — Apply qalos customizations (1 min)

```bash
cd ~/aosp
~/qalos/tools/apply-qalos.sh
```

Expected tail of output: `[apply-qalos] done.`

This copies the qalos device tree, the QaLab app, and (when present) the
qalos vendor blobs from the cloned qalos repo into the AOSP source tree.
It's safe to re-run after a `git pull` in `~/qalos`.

---

## Step 8 — Pick the build target (1 min)

```bash
cd ~/aosp
source build/envsetup.sh
lunch qalos_emulator-userdebug
```

Expected tail of output should include:

```
TARGET_PRODUCT=qalos_emulator
TARGET_BUILD_VARIANT=userdebug
TARGET_ARCH=x86_64
```

If `lunch` does not list `qalos_emulator-userdebug`, step 7 didn't apply
correctly. Re-run it and look for errors.

---

## Step 9 — Build (1–2 hours)

```bash
cd ~/aosp
m -j$(nproc) 2>&1 | tee ~/qalos/.build.log
```

This compiles everything. **Do not interrupt.** The final link step can
take 30+ minutes on its own and is not safe to abort.

To monitor in another shell: `tail -20 ~/qalos/.build.log`.

**Common failure modes**:

- `FAILED: ... out of memory` → drop to `m -j$(nproc-1)` and re-run. If
  it still OOMs, the box doesn't have enough RAM.
- `FAILED: ninja: error: manifest '...'` → usually a stale state. Run
  `make clean` and re-run step 9.
- `FAILED: ... module not found` → re-run step 7.
- Build appears hung at >80% → probably the link step. Wait. Java /
  `d8` / `dex2oat` are slow.

---

## Step 10 — Verify the built images

```bash
ls -la ~/aosp/out/target/product/qalos_emulator/
```

Expected core files (all non-zero size):

- `system.img` (~1–2 GB)
- `boot.img` (~30–50 MB)
- `userdata.img` (~5–10 MB)

If all three are present and non-zero, the build succeeded. Optional
artifacts that may also be present: `ramdisk.img`, `vendor.img`,
`qalos_emulator-img-*.zip`.

---

## Step 11 — Report back

Reply with this exact structure so the parent agent can parse it:

```
qalos build: SUCCESS | FAILED
duration: <Xh Ym>
disk used: <X GB>
system.img: <size MB or GB>
location: /home/<user>/aosp/out/target/product/qalos_emulator/
log files: ~/qalos/.repo-sync.log, ~/qalos/.build.log

failures (if any):
  - <one-line description>
  - <one-line description>

recommendations:
  - <one-line next step>
  - <one-line next step>
```

If `SUCCESS`: the qalos fork is viable. The next steps would be to boot
the AVD with the built image to confirm it actually runs, or to start
adding real qalos apps / customisations.

If `FAILED`: include the last 50 lines of `~/qalos/.build.log` and the
exact step that failed (step 1–10 above). Don't truncate the error
trace.

---

## Cleanup (optional, after SUCCESS)

To free ~150 GB once the build is verified:

```bash
rm -rf ~/aosp/out           # build output
ccache -C                   # ccache directory (separate, up to 20 GB)
# keep ~/aosp/.repo/ and the source — they're needed for incremental builds
```
