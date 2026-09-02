# qalos — QA Lab Operating System

qalos is an Android-based operating system (a fork of AOSP) for QA Lab use, with **Samsung Galaxy A16 5G** as the long-term target device and the **Android emulator (AVD)** as the day-to-day build/test target.

The fork is bare-bones: same kernel, same HALs as upstream AOSP, with a custom product makefile that overrides the OS branding (`QA Lab Operating System`, build id `QAL.YYYYMMDD.001`) and ships one first-party app (`QaLab`).

## Two ways to build

| | Local Linux box (main) | DO droplet / GH Actions (fallback) |
| --- | --- | --- |
| **Use it for** | Day-to-day dev and builds | Clean-room CI, repro builds, sharing a build with a colleague |
| **Setup cost** | One-time `apt install` on your box | One-time DO account + snapshot |
| **Standing cost** | $0 (your box, your power) | $0.40/month snapshot + $5/month Spaces |
| **Per build** | $0 | ~$0.50–$0.80 (c-8) |
| **First build time** | 2–4 hours | 2–4 hours (same speed) |
| **Iterating** | Re-run `apply-qalos.sh && m -j$(nproc)` | One full droplet cycle per build |
| **Docs** | [`docs/local-build.md`](docs/local-build.md) | this README, below |

**Recommended: build locally**, use the DO / GH Actions path for clean-room CI.

## Local build (main workflow)

You need a Linux box with Ubuntu 22.04+, 16 GB+ RAM, and 200+ GB free disk. The full walkthrough is in [`docs/local-build.md`](docs/local-build.md). The short version:

```bash
# one-time setup
sudo apt-get install -y --no-install-recommends \
    git gnupg flex bison gperf build-essential zip curl zlib1g-dev \
    gcc-multilib g++-multilib libc6-dev-i386 lib32ncurses5-dev x11proto-core-dev \
    libx11-dev lib32z1-dev libgl1-mesa-dev libxml2-utils xsltproc unzip m4 bc \
    openjdk-17-jdk-headless python3 python3-pip rsync ccache jq
sudo curl -fsSL https://storage.googleapis.com/git-repo-downloads/repo \
    -o /usr/local/bin/repo && sudo chmod +x /usr/local/bin/repo
git config --global user.email "you@example.com" && git config --global user.name "Your Name"

# first build
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j$(nproc) --no-tags --no-clone-bundle        # 1-2 hours, first time only
../qalos/tools/apply-qalos.sh                              # if you cloned qalos next to aosp
. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc)                                               # 1-2 hours, first time
```

The three images you want land in `~/aosp/out/target/product/qalos_emulator/`: `system.img`, `boot.img`, `userdata.img`.

## Fallback: build on a DigitalOcean droplet (clean-room CI)

The `doctl-*.ps1` scripts and `.github/workflows/build.yml` stay in the repo for when you need a build that proves nothing on your local box is influencing the result. A `c-8: 8 vCPU / 16 GB / 200 GB SSD` droplet is created from a pre-warmed `qalos-build-warm` snapshot, the build runs on it, the artifacts upload to DO Spaces, and the droplet is destroyed. Four redundant safety nets guarantee the droplet can never be left running:

1. `try/finally` in the PowerShell scripts (clean exit, Ctrl+C, errors).
2. Background `Start-Job` watchdog that force-destroys the droplet if the parent PowerShell dies (`kill -9`).
3. On-droplet bash watchdog in `do-build.sh` that `shutdown -h now`s at `MAX_RUNTIME_MINUTES` (catches orchestrator-unreachable).
4. GH Actions `if: always()` cleanup step with `timeout-minutes: 360`.

To set this up once: see [`docs/setup.md`](docs/setup.md) for the manual steps. To trigger a build:

```powershell
# from this Windows box
.\tools\doctl-build.ps1
```

Or push to `main` on GitHub, or click **Run workflow** in the Actions tab.

## Repo layout

```
.
├── default.xml                            # the AOSP manifest; pins android-15.0.0_r1
├── device/qalos/qalos_emulator/           # qalos product makefile (branding, build id)
├── packages/apps/QaLab/                   # the only first-party qalos app
├── tools/
│   ├── apply-qalos.sh                     # copy qalos content from manifest repo to AOSP working tree
│   ├── setup-droplet.sh                   # one-time base-droplet setup (AOSP build deps)
│   ├── do-build.sh                        # build script (used by the DO on-demand flow)
│   ├── doctl-install.ps1                  # install doctl on this Windows box
│   ├── doctl-setup-base.ps1               # one-time: create base droplet + snapshot
│   ├── doctl-build.ps1                    # on-demand build trigger
│   └── doctl-avd.ps1                      # on-demand AVD trigger
├── .github/workflows/build.yml            # GH Actions workflow (fallback CI)
├── docs/
│   ├── local-build.md                     # the main build workflow
│   └── setup.md                           # one-time DO / GH Actions setup
└── README.md                              # you are here
```

## Device support

| Target | Status |
| --- | --- |
| x86_64 emulator (AVD) | **First target.** `lunch qalos_emulator-userdebug` builds a working AVD. |
| Samsung Galaxy A16 5G (Exynos 1330, SM-A166B) | **Future.** Needs Samsung's kernel + HAL from `opensource.samsung.com` and a custom device tree. Multi-month port; the upstream community (`LineageOS`, `crDroid`) usually has a head start worth tracking. |

## Cost

| Resource | Standing | Per build |
| --- | --- | --- |
| Local Linux box | $0 (your hardware, your power) | $0 |
| `qalos-build-warm` snapshot (fallback only) | $0.40/month | — |
| DO Spaces (fallback only) | $5/month | — |
| Fallback build droplet (c-8) | $0 | $0.50–$0.80 |

Idle project cost if you use the fallback flow: **~$5.40/month**. Idle cost if you use only the local box: **$0**.
