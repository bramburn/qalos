---
sidebar_position: 2
---

# Architecture overview

The opinionated design rules that govern every script in `tools/`. The canonical source is [`AGENTS.md`](https://github.com/bramburn/qalos/blob/main/AGENTS.md) in the repo root.

## Three build paths

| Path | When to use | Standing cost | Per-build cost | Build time |
| --- | --- | --- | --- | --- |
| **Local Linux box** (primary) | Day-to-day dev, fast iteration | $0 | $0 | 1-4 h |
| **DigitalOcean droplet** (fallback #1) | Clean-room CI, share a build | ~$5.40/mo | $0.50-0.80 | 2-4 h |
| **Aliyun ECS** (fallback #2) | China region, cheaper spot | ~¥1-6/mo | ¥7-14 | 2-4 h |

**Default to local.** Cloud is a fallback, not the default.

## The single source of truth

`tools/do-build.sh` is the **only** on-host build script. Both the DO and the Aliyun orchestrators invoke it. If the AOSP build steps ever change — different target, different variant, different flags — they change in **one place**.

The orchestrator handles:

1. Launching the build instance.
2. Waiting for it to be SSH-ready.
3. Scp'ing `do-build.sh` (and the env file) onto it.
4. Running it.
5. Pulling artifacts off it.
6. Destroying the instance — no matter what.

The on-host script handles:

1. AOSP repo sync.
2. Build (`source build/envsetup.sh && lunch ... && m -j$(nproc)`).
3. Artifact upload to cloud storage (currently DO Spaces).

## The design rules

These are non-negotiable. If a future change violates one, it should be a deliberate, documented exception.

### Local first, cloud only when justified

$0 marginal cost, fast iteration, no rate limits. Cloud is for clean-room CI and sharing, not for everyday dev.

### The warm-image pattern

**Never reinstall build dependencies on every run.** Both cloud paths create a "warm" base image once (`doctl-setup-base.ps1` makes a DO snapshot, `aliyun-setup-base.ps1` makes an Aliyun custom image) and then launch every subsequent build from that image. This is the single biggest cost + time win for cloud builds:

- DO: eliminates ~30 min of `apt install` per build.
- Aliyun: same.

The cost of the warm artefact:

- DO snapshot: $0.10/GB/month, ~3-4 GB → ~$0.40/month.
- Aliyun custom image: ¥0.12/GB/month, ~8-12 GB → ~¥1/month.

Both are cheaper than one wasted build cycle. See [Warm-image pattern](warm-image-pattern).

### Four safety nets, no exceptions

Every on-demand build script must guarantee the build instance is destroyed, even on parent process death, hard kill, network loss, or uncaught exception. The DO path has four redundant safety nets; the Aliyun path mirrors three of them (GH Actions #4 doesn't apply locally). See [Safety nets](safety-nets).

### Spot/preemptible for compute, never for storage

Both providers offer deep discounts on interruptible instances (DO: spot; Aliyun: `SpotStrategy=SpotAsPriceGo`). Use them for the build instances — a 5-minute spot reclaim mid-build is recoverable (just relaunch from the warm image, `repo sync` resumes from where it left off, and `ccache` survives).

Don't use spot for the warm image store itself — that's a custom image / snapshot, and if it gets reclaimed you've lost the 30 min of setup work.

### Provider is a parameter, not a hard-coded choice

`do-build.sh` is provider-agnostic. The orchestrator (PowerShell or shell) is what knows about DO or Aliyun. The cloud primitives differ:

- DO has `droplet create/delete`, `snapshot create`, `compute action`.
- Aliyun has `RunInstances`, `DeleteInstance`, `CreateImage`, `StopInstance`, with VPC/vSwitch/SG/KeyPair as separate resources.

But the **shape** is the same: launch → wait → run on-host script → scp artifacts → destroy. If you ever add a third provider (Hetzner? GCP?), the existing scripts are the template.

### State is on disk, in the repo

The Aliyun orchestrators read infra state from `.pi/aliyun-state.json`, written by `aliyun-smoke-test.ps1`. This makes the scripts idempotent (re-runs reuse existing VPC/SG/keypair) and makes the infra visible to any agent reading the repo. The file is in `.pi/` (already in `.gitignore` per commit `d640d4e`).

The DO path is stateless because doctl resolves the warm snapshot by name on every run. The Aliyun path is stateful because the VPC/vSwitch/SG/KeyPair aren't discoverable by name in the same convenient way.

## Cost rules

| Item | Standing | Per AOSP build |
| --- | --- | --- |
| Local Linux box | $0 | $0 |
| DO `qalos-build-warm` snapshot | $0.40/mo | — |
| DO Spaces | $5/mo | (storage for build artifacts) |
| DO build droplet (`c-8`) | $0 | $0.50-0.80 |
| Aliyun `qalos-build-warm` custom image | ~¥1/mo | — |
| Aliyun build ECS (`u1-c1m8.2xlarge` spot, 6h) | $0 | ~¥7 |
| Aliyun egress (scp 10 GB to UK) | $0 | ~¥8 |

**Idle project cost if you only use the local box: $0.**
**Idle project cost if you maintain the DO fallback: ~$5.40/month.**
**Idle project cost if you maintain the Aliyun fallback: ~¥6/month (¥1 image + ¥5 from a default OSS bucket if you add one).**

If you maintain both fallbacks, set the unused one to no warm artefact and accept the 30 min re-setup cost the next time you need it.

## What's next

- Want to know the four safety nets in detail? → [Safety nets](safety-nets)
- Want to know why the warm-image pattern works? → [Warm-image pattern](warm-image-pattern)
- Looking for a specific script's docs? → [Tools reference](../reference/tools-reference)
