---
sidebar_position: 1
---

# Getting started

Three ways to build qalos, ordered by what you should pick first.

## 1. Local Linux box (primary)

The right choice for day-to-day dev. ~$0 marginal cost, no rate limits, no SSH round-trip.

**Prereqs:** Ubuntu 22.04+, 16 GB+ RAM, 200+ GB free disk.

→ [Local build walkthrough](local-build)

## 2. DigitalOcean droplet (fallback #1)

The right choice when you need a clean-room build (proves nothing on your local box is influencing the result), or you're sharing a build with a colleague.

**Standing cost:** ~$5.40/month (Spaces + warm snapshot).
**Per build:** ~$0.50-0.80 (c-8).

→ [DO build walkthrough](do-build)

## 3. Aliyun ECS (fallback #2)

The right choice when you need a China-region run, when DO is unavailable, or when Aliyun's spot pricing on the chosen instance type is better.

**Standing cost:** ~¥1/month (warm custom image).
**Per build:** ~¥7-14 (ecs.u1-c1m8.2xlarge spot, 6h).

→ [Aliyun build walkthrough](aliyun-build)

## What's the same on all three

The AOSP build steps. The on-host script `tools/do-build.sh` is identical for local, DO, and Aliyun — only the way you launch and the way you ssh/connect differ. See [Architecture overview](../architecture/overview).
