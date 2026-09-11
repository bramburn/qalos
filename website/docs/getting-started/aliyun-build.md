---
sidebar_position: 4
---

# Aliyun build (fallback #2)

The Aliyun path is the right pick when you need a China-region run, when DO
is unavailable, or when Aliyun's spot pricing on the chosen instance type
is better. As of 2026-09-09 the build is **LLM-driven, not script-driven**
(see [`tools/aliyun/AGENTS.md`](https://github.com/bramburn/qalos/blob/main/tools/aliyun/AGENTS.md)).
This page documents what the LLM does and why.

## Prerequisites

- An Alibaba Cloud account (China mainland region for the best AOSP source mirror).
- An AccessKey ID + Secret (RAM user, not root; the RAM user must be **Enabled** and have a policy attached — see [Gotchas](../reference/gotchas.md)).
- The Aliyun CLI installed (`aliyun` 3.4.0+; we use 3.4.11).
- A Windows / macOS / Linux machine to run the orchestrator from.

## What runs in which region (as of 2026-09-11)

The Aliyun build path has been split into **two regions**:

| Region | Role | Why |
| --- | --- | --- |
| **cn-hongkong** | Source-tree staging. Run a small ECS that downloads the compressed source from HK OSS, extracts it, and gets snapshotted. | HK OSS public endpoint is not blocked at the account level (cn-guangzhou is — see [Gotchas](../reference/gotchas.md)). HK ECS internal-OSS download is 5–10× faster than public. |
| **cn-guangzhou** | The actual build. Run the production `m -jN` on a large instance (16 vCPU / 64 GB+) launched from the HK-built custom image. | Best AOSP mirror availability in mainland China. `SpotAsPriceGo` pricing on `ecs.u1-c1m8.2xlarge` is ~¥7/6h. |

The **HK → cn-guangzhou** link is `aliyun ecs CopyImage --DestinationRegionId cn-guangzhou`,
which is free and intra-Aliyun-fast.

**Why not just do everything in cn-hangzhou or cn-guangzhou?**

- **cn-hangzhou outbound connectivity varies per zone.** As of
  2026-09-10, some zones (`cn-hangzhou-i`) had **zero outbound** —
  every `curl` returned `code=000`. The original 5 attempts were
  in `cn-hangzhou-j` (which had IPv6-only outbound). Do not assume
  "different zone = different policy = will work." See
  [`tools/aliyun/LESSONS.md`](https://github.com/bramburn/qalos/blob/main/tools/aliyun/LESSONS.md).
- **cn-guangzhou public OSS endpoint is blocked at the account level** on
  this account. Symptom: `PublicEndpointForbidden` (HTTP 400, code
  `0048-00000401`). HK's public endpoint is fine.
- **UK → cn-guangzhou SSH is DPI-throttled to ~1 KB/s** — see
  [Gotchas](../reference/gotchas.md) § "UK → cn-guangzhou SSH
  throttling." HK is unmetered.

## Is `ecs.u1-c1m8.2xlarge` enough for the build?

**Yes**, with a caveat. That's Google's documented AOSP minimum (8 vCPU /
64 GB). A build takes 5-6 hours on it. If the wait becomes painful, step up
to `ecs.u1-c1m8.4xlarge` (16 vCPU / 128 GB) which cuts to 3-4 hours. For
Android 17+ (future), make 4xlarge the default.

For a one-off AOSP build, the cost is ~¥7 on 2xlarge spot or ~¥14 on
4xlarge spot. Both are cheap enough to be the right default.

## One-time setup (~20 min)

```bash

# 1. Install the Aliyun CLI (skipped if already installed)
#    Windows:  .\tools\aliyun-install.ps1
#    macOS/Linux: ./scripts/aliyun-install.sh

# 2. Configure credentials (one-time, interactive)
aliyun configure
# - Region: cn-hongkong (NOT cn-guangzhou — see Why two regions above)
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

## Per-build (~2-6 h, LLM-driven)

The build is no longer scripted — it's driven by the LLM following the runbook in
[`tools/aliyun/AGENTS.md`](https://github.com/bramburn/qalos/blob/main/tools/aliyun/AGENTS.md).
At a high level, the LLM does:

```powershell

# 1. Launch the build VM (the warm image, spot-priced, in cn-guangzhou)
$instance = aliyun ecs RunInstances --RegionId cn-guangzhou `
    --ImageId m-<warm-image-id> `
    --InstanceType ecs.u1-c1m8.2xlarge `
    --InstanceChargeType PostPaid --SpotStrategy SpotAsPriceGo `
    --VSwitchId vsw-7xvvy64syomut0vdu6iin `
    --SecurityGroupId sg-7xv0xvsywi6cm82ea65c `
    --KeyPairName qalos-aosp-key-ed25519 `
    --SystemDisk.Category cloud_essd --SystemDisk.Size 500

# 2. Wait for Running, upload do-build.sh
ssh ...  scp ... tools/do-build.sh root@<IP>:/tmp/

# 3. Launch the build detached (systemd-run) so it survives the SSH session
ssh ...  systemd-run --unit=qalos-resumeN --setenv=QALOS_REPO_URL=... \
        /bin/bash /tmp/do-build.sh

# 4. Set up a mavis cron that owns teardown
mavis cron create --cron_name "qalos-build-<NAME>" --schedule "*/10 * * * *" `
        --prompt "..." --session '{"mode":"sessionId","sessionId":"<this>"}'

# 5. Detach — the cron monitors, downloads artifacts, and deletes the instance
```

The on-host `do-build.sh` runs the same way it does for DO and GCP: preflight
(api-stubs-docs-non-updatable) → `repo sync` → `lunch qalos_emulator-userdebug`
→ `m -jN` → write artifacts → write the token-gated download URL.

The artifacts land in `out/aliyun-build/` after you curl them down via the
URL in `/tmp/qalos-artifacts-url.txt`.

## AOSP source migration to Aliyun (one-time per AOSP version)

If you don't already have a cn-guangzhou image with AOSP 15 source ready to
build, you first need to ship the source from your local Linux box to
Aliyun. This is **not** a `scp` operation — it has its own multi-hour
recipe. See [AOSP source migration to Aliyun](./aosp-source-migration.md) for the full
HK-relay pattern (Mac Mini → HK OSS → HK ECS → extract → snapshot →
CopyImage → cn-guangzhou). Total wall time: ~2.5–3.5 hours.

## Standing cost

| Item | Cost |
| --- | --- |
| `qalos-build-warm` custom image (~8-12 GB) | ~¥8-12/month |
| `qalos-aosp-base-v1` AOSP source image (~20-30 GB after extract) | ~¥8-12/month |
| HK OSS bucket `qalos-aosp-hk` (data + requests) | ~¥1/month if data deleted after download |
| **Total if you maintain the fallback** | **~¥17-25/month** |

Egress from `cn-hangkong` to the UK is ~¥0.08/GB; from `cn-guangzhou` is
~¥0.12/GB. A 10 GB AOSP image costs ~¥0.80–1.20 to scp home.

## When to pick Aliyun over DO

- **You're in or close to China.** AOSP's Tsinghua TUNA mirror is fast from China; the `repo sync` step takes 1-2 hours instead of 4-6 from Europe.
- **DO is unavailable** in your region or you have a free Aliyun trial credit to burn.
- **You want a separate cloud for fail-over.** The DO and Aliyun paths are independent — if DO has an outage, Aliyun is unaffected.

## The known caveats

The Aliyun path has several sharp edges that DO doesn't. The full list is
in [Gotchas](../reference/gotchas.md). The most important ones (as of
2026-09-11):

1. **`PublicEndpointForbidden` on cn-guangzhou public OSS** — your
   `ossutil cp` to `oss-cn-guangzhou.aliyuncs.com` fails with HTTP 400.
   HK is fine; use HK OSS as the staging layer (see [AOSP source migration](./aosp-source-migration.md)).
2. **UK → cn-guangzhou SSH is DPI-throttled to ~1 KB/s.** Don't try to
   rsync 35 GB over SSH; it'll take 281 days.
3. **The new-account `RunInstances` rate limit** — first-day accounts are
   throttled to 1-2 `RunInstances` per minute. If you see `SDK.ServerError`
   on the first build, wait 60-90 seconds and retry.
4. **`oss-cn-<region>-internal.aliyuncs.com` is 5–10× faster than public**
   when downloading into an ECS. Always use the internal endpoint from
   inside Aliyun (you can't reach it from outside).
5. **ECS sizing for extraction** — `ecs.u1-c1m2.large` (2 vCPU / 2 GB)
   is too small for extracting 35 GB → 127 GB. Use `ecs.u1-c1m4.large`
   (4 vCPU / 8 GB) for that phase. 2 GB RAM will swap so hard that SSH
   becomes unresponsive.

## What's next

- New to the project? → [AOSP source migration to Aliyun](./aosp-source-migration.md)
  to get the source into Aliyun before your first build.
- Want to understand the four safety nets? → [Safety nets](../architecture/safety-nets.md)
- Hit an Aliyun `SDK.ServerError`? → [Gotchas](../reference/gotchas.md)
- Want to set up a GH Actions path for Aliyun too? → copy `.github/workflows/build.yml`
  to `build-aliyun.yml` and follow the pattern. (Not done in this commit because
  the GH secrets need to be set first.)
