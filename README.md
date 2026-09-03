# qalos — QA Lab Operating System

[![License: MIT](https://img.shields.io/badge/license-MIT-blue.svg)](LICENSE)
[![Upstream: AOSP android-15.0.0_r1](https://img.shields.io/badge/AOSP-android--15.0.0__r1-3DDC84?logo=android)](https://source.android.com/)
[![Docs: GitHub Pages](https://img.shields.io/badge/docs-github%20pages-blue)](https://bramburn.github.io/qalos/)
[![CI](https://img.shields.io/github/actions/workflow/status/bramburn/qalos/ci.yml?branch=main&label=CI)](.github/workflows/ci.yml)

qalos is an Android-based operating system (a fork of [AOSP](https://source.android.com/)) for QA Lab use, with **Samsung Galaxy A16 5G** as the long-term target device and the **Android emulator (AVD)** as the day-to-day build/test target.

The fork is bare-bones: same kernel, same HALs as upstream AOSP, with a custom product makefile that overrides the OS branding (`QA Lab Operating System`, build id `QAL.YYYYMMDD.001`) and ships one first-party app (`QaLab`).

- **Upstream:** derivative of AOSP at `android-15.0.0_r1`. The manifest in this repo includes the upstream AOSP manifest verbatim; qalos only adds product metadata, one first-party app, and the build / CI scripts. Upstream AOSP is licensed under Apache 2.0; see the attribution note at the bottom of [`LICENSE`](LICENSE).
- **License:** MIT for the original qalos contributions (QaLab, product makefile, build scripts, documentation). The bundled AOSP components remain under their upstream Apache 2.0 license.

## What can I do with it?

| I want to... | Then read... |
| --- | --- |
| Build on my Linux box in 1-4 hours | [Local build](https://bramburn.github.io/qalos/docs/getting-started/local-build) |
| Build on DigitalOcean (clean-room CI) | [DO build](https://bramburn.github.io/qalos/docs/getting-started/do-build) |
| Build on Alibaba Cloud / Aliyun (China region, cheap) | [Aliyun build](https://bramburn.github.io/qalos/docs/getting-started/aliyun-build) |
| Understand the architecture and design rules | [Architecture overview](https://bramburn.github.io/qalos/docs/architecture/overview) |
| Add a feature, fix a bug, send a PR | [CONTRIBUTING.md](CONTRIBUTING.md) |
| Browse the API / folder reference | [Reference](https://bramburn.github.io/qalos/docs/reference/folder-structure) |

## Quick start (local Linux box)

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

# first build (1-4 hours, depending on machine)
mkdir -p ~/aosp && cd ~/aosp
repo init -u https://github.com/bramburn/qalos -b main
repo sync -c -j$(nproc) --no-tags --no-clone-bundle
../qalos/tools/apply-qalos.sh
. build/envsetup.sh
lunch qalos_emulator-userdebug
m -j$(nproc)
```

The three images you want land in `~/aosp/out/target/product/qalos_emulator/`: `system.img`, `boot.img`, `userdata.img`.

## Two cloud fallbacks

| | DigitalOcean | Aliyun (China) |
| --- | --- | --- |
| Use it for | Clean-room CI, sharing a build | Same; pick when you need China region, cheaper spot, or DO is down |
| Standing cost | ~$5.40/mo (Spaces + warm snapshot) | ~¥1/mo (warm custom image) |
| Per build | ~$0.50-0.80 (c-8 spot) | ~¥7-14 (u1-c1m8.2xlarge spot) |
| Setup cost | One-time `doctl-setup-base.ps1` (~10 min) | One-time `aliyun-smoke-test.ps1` + `aliyun-setup-base.ps1` (~20 min total) |
| Trigger | `./tools/doctl-build.ps1` | `./tools/aliyun-build.ps1` |

Full walkthroughs in the [docs site](https://bramburn.github.io/qalos/docs/getting-started/).

## Device support

| Target | Status |
| --- | --- |
| x86_64 emulator (AVD) | **First target.** `lunch qalos_emulator-userdebug` builds a working AVD. |
| Samsung Galaxy A16 5G (Exynos 1330, SM-A166B) | **Future.** Needs Samsung's kernel + HAL from `opensource.samsung.com` and a custom device tree. Multi-month port; the upstream community (`LineageOS`, `crDroid`) usually has a head start worth tracking. |

## Cost

| Resource | Standing | Per build |
| --- | --- | --- |
| Local Linux box | $0 (your hardware, your power) | $0 |
| DO `qalos-build-warm` snapshot (fallback only) | $0.40/month | — |
| DO Spaces (fallback only) | $5/month | — |
| DO build droplet (c-8) | $0 | $0.50-0.80 |
| Aliyun `qalos-build-warm` custom image (fallback only) | ~¥1/month | — |
| Aliyun build ECS (u1-c1m8.2xlarge spot, 6h) | $0 | ~¥7 |

**Idle project cost: $0** (if you only use the local box). **~$5.40/month** (if you maintain the DO fallback). **~$5.40 + ¥6/month** (if you maintain both fallbacks).

## Contributing

See [CONTRIBUTING.md](CONTRIBUTING.md). All PRs require an approval before they can merge (see [BRANCH_PROTECTION.md](BRANCH_PROTECTION.md)). The CI pipeline runs static checks only — AOSP builds are not run on GitHub Actions.

## License

MIT for qalos contributions; Apache 2.0 for bundled AOSP components. See [LICENSE](LICENSE) for full text.
