---
sidebar_position: 4
---

# Aliyun build (fallback #2)

The Aliyun path is the right pick when you need a China-region run, when DO is unavailable, or when Aliyun's spot pricing on the chosen instance type is better. The scripts mirror the DO path's structure but with Aliyun primitives (ECS, custom image, VPC/vSwitch/SG/KeyPair).

## Prerequisites

- An Alibaba Cloud account (China mainland region for the best AOSP source mirror).
- An AccessKey ID + Secret (RAM user, not root).
- The Aliyun CLI installed (`aliyun` 3.4.0+; we use 3.4.11).
- A Windows / macOS / Linux machine to run the orchestrator from.

## Is `ecs.u1-c1m8.2xlarge` enough?

**Yes**, with a caveat. That's Google's documented AOSP minimum (8 vCPU / 64 GB). A build takes 5-6 hours on it. If the wait becomes painful, step up to `ecs.u1-c1m8.4xlarge` (16 vCPU / 128 GB) which cuts to 3-4 hours. For Android 17+ (future), make 4xlarge the default.

For a one-off AOSP build, the cost is ~¥7 on 2xlarge spot or ~¥14 on 4xlarge spot. Both are cheap enough to be the right default.

## One-time setup (~20 min)

```bash
# 1. Install the Aliyun CLI (skipped if already installed)
#    Windows:  .\tools\aliyun-install.ps1
#    macOS/Linux: ./scripts/aliyun-install.sh

# 2. Configure credentials (one-time, interactive)
aliyun configure
# - Region: cn-hangzhou (or your preferred region)
# - AccessKey ID / Secret: from the RAM user you created
# - Language: en

# 3. Smoke test: prove the end-to-end works + bootstrap the supporting infrastructure
#    Windows:  .\tools\aliyun-smoke-test.ps1
#    macOS/Linux: ./scripts/aliyun-smoke-test.sh

# 4. Create the warm custom image (matches the build instance type)
.\tools\aliyun-setup-base.ps1 -InstanceType ecs.u1-c1m8.2xlarge
#    macOS/Linux: ./scripts/aliyun-setup-base.sh --instance-type ecs.u1-c1m8.2xlarge
```

The setup script:
1. Launches a base ECS in the same VPC/vSwitch/SG/KeyPair the smoke test created.
2. Runs `tools/setup-droplet.sh` to install every AOSP build dependency.
3. Stops the base ECS.
4. Creates a custom image called `qalos-build-warm` (~8-12 GB).
5. Deletes the base ECS.

The custom image is the artefact you keep. Every subsequent build launches from it, skipping the 30-min `apt install`.

## Per-build (~2-6 h)

```bash
# Windows
.\tools\aliyun-build.ps1 -InstanceType ecs.u1-c1m8.2xlarge -MaxRuntimeMinutes 360
# macOS/Linux
./scripts/aliyun-build.sh --instance-type ecs.u1-c1m8.2xlarge --max-runtime-minutes 360
```

The build script:
1. Launches an ECS from the `qalos-build-warm` custom image.
2. Waits for SSH.
3. Scp's `tools/do-build.sh` (and an env file) onto it.
4. Starts an on-host watchdog that force-shuts-down the instance at `MAX_RUNTIME_MINUTES`.
5. Runs the build (this is the long part — 1-6 hours).
6. Pulls the resulting `*.img` files off via scp.
7. Destroys the ECS — no matter what (try/finally + Start-Job watchdog + on-host watchdog).

The artifacts land in `out/aliyun-build/`.

## Standing cost

| Item | Cost |
| --- | --- |
| `qalos-build-warm` custom image (~8-12 GB) | ~¥1/month |
| OSS bucket (optional, for artifact storage) | ~¥5/month if you add one |
| **Total if you maintain the fallback** | **~¥1-6/month** |

Egress from `cn-hangzhou` to the UK is ~¥0.12/GB. A 10 GB AOSP image costs ~¥1.20 to scp home.

## When to pick Aliyun over DO

- **You're in or close to China.** AOSP's Tsinghua TUNA mirror is fast from China; the `repo sync` step takes 1-2 hours instead of 4-6 from Europe.
- **DO is unavailable** in your region or you have a free Aliyun trial credit to burn.
- **You want a separate cloud for fail-over.** The DO and Aliyun paths are independent — if DO has an outage, Aliyun is unaffected.

## The known caveats

The Aliyun path has a few sharp edges that DO doesn't. The full list is in [Gotchas](../reference/gotchas), but the most important one is **the new-account `RunInstances` rate limit**: first-day accounts are throttled to 1-2 `RunInstances` per minute. If you see `SDK.ServerError` on the first build, wait 60-90 seconds and retry.

## What's next

- Want to understand the four safety nets? → [Safety nets](../architecture/safety-nets)
- Hit an Aliyun `SDK.ServerError`? → [Gotchas](../reference/gotchas)
- Want to set up a GH Actions path for Aliyun too? → copy `.github/workflows/build.yml` to `build-aliyun.yml` and follow the pattern. (Not done in this commit because the GH secrets need to be set first.)
