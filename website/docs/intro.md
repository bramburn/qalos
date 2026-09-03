---
id: intro
title: Introduction
slug: /
sidebar_position: 1
---

# qalos

**QA Lab Operating System** — an AOSP fork for QA Lab use.

qalos is bare-bones: same kernel, same HALs as upstream AOSP, with a custom product makefile that overrides the OS branding (`QA Lab Operating System`, build id `QAL.YYYYMMDD.001`) and ships one first-party app (`QaLab`).

- **Upstream:** derivative of AOSP at `android-15.0.0_r1`
- **First target:** x86_64 emulator (AVD). `lunch qalos_emulator-userdebug` builds a working AVD.
- **Future target:** Samsung Galaxy A16 5G (Exynos 1330, SM-A166B). Multi-month port; not in this repo's scope yet.
- **License:** MIT for qalos contributions; Apache 2.0 for bundled AOSP components.

## Three build paths

| Path | When to use | Cost per build |
| --- | --- | --- |
| **Local Linux box** (primary) | Day-to-day dev, fast iteration | $0 |
| **DigitalOcean droplet** (fallback #1) | Clean-room CI, sharing a build | ~$0.50-0.80 |
| **Aliyun ECS** (fallback #2) | China region, cheaper spot pricing | ~¥7-14 |

**Default to local.** Cloud is for clean-room CI and sharing, not for everyday dev. See [Architecture overview](architecture/overview) for why.

## Where to start

- New to qalos? → [Local build](getting-started/local-build)
- Want a clean-room CI build? → [DO build](getting-started/do-build) or [Aliyun build](getting-started/aliyun-build)
- Want to understand the design rules? → [Architecture overview](architecture/overview)
- Want to send a PR? → [How to contribute](contributing/how-to-contribute)
- Looking up a script or file? → [Tools reference](reference/tools-reference) or [Folder structure](reference/folder-structure)
- Hit an Aliyun `SDK.ServerError`? → [Gotchas](reference/gotchas)

## The single source of truth

`tools/do-build.sh` is the **only** on-host build script. Both the DO and the Aliyun orchestrators invoke it. If the AOSP build steps ever change — different target, different variant, different flags — they change in **one place**.

The orchestrator (PowerShell or shell) handles:

1. Launching the build instance.
2. Waiting for it to be SSH-ready.
3. Scp'ing `do-build.sh` (and the env file) onto it.
4. Running it.
5. Pulling artifacts off it.
6. Destroying the instance — no matter what.

The on-host script handles:

1. AOSP repo sync.
2. Build (`source build/envsetup.sh && lunch ... && m -j$(nproc)`).
3. Artifact upload to cloud storage (currently DO Spaces, see [Gotchas](reference/gotchas) for the Aliyun caveat).
