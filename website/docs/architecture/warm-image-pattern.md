---
sidebar_position: 4
---

# Warm-image pattern

**Never reinstall build dependencies on every run.** Both cloud paths create a "warm" base image once and then launch every subsequent build from that image. This is the single biggest cost + time win for cloud builds.

## The pattern

```
   ┌──────────────┐
   │ One-time     │  doctl-setup-base.ps1   (or aliyun-setup-base.ps1)
   │ setup        │  ────────────────────►
   │              │   1. launch base instance from stock image
   │              │   2. run setup-droplet.sh (apt install, repo, ccache, ...)
   │              │   3. snapshot (DO) / create custom image (Aliyun)
   │              │   4. delete base instance
   │              │  ◄────────────────────
   │              │   artefact: qalos-build-warm snapshot/image
   └──────────────┘
   
   ┌──────────────┐
   │ Per-build    │  doctl-build.ps1   (or aliyun-build.ps1)
   │ (~5 min)     │  ────────────────────►
   │              │   1. launch build instance from qalos-build-warm
   │              │   2. scp do-build.sh onto it
   │              │   3. run build (1-6 hours)
   │              │   4. scp artifacts off
   │              │   5. destroy build instance
   │              │  ◄────────────────────
   └──────────────┘
```

The setup runs **once**. After that, every per-build skips the 30-60 min `apt install` and goes straight to running the build.

## Why this matters

Without the warm image, every build:

- Spends 5-10 min just booting.
- Spends 30-60 min running `apt install` for ~50 build dependencies (gcc, g++, java, repo, ccache, flex, bison, ...).
- Spends 30-60 min running `repo sync` (downloading 80+ GB of AOSP source from scratch).

That's an hour of setup before the build even starts. With the warm image:

- The `apt install` step is already done — the image is pre-baked.
- The AOSP source is **not** in the image (it changes too often to bake in), but `ccache` is, so even a cold `repo sync` + first build is faster than from a stock image.

Net savings: ~30 min per build × N builds/month. For a project that builds 4 times a month, that's 2 hours/month of CI time — and 2 hours of compute cost on a ¥15/hour instance (¥30).

## The cost of the warm artefact

| Provider | What it is | Monthly cost | Build cost saving |
| --- | --- | --- | --- |
| DO | `qalos-build-warm` snapshot, ~3-4 GB | ~$0.40 | Saves ~30 min × $0.10/min = $3 per build |
| Aliyun | `qalos-build-warm` custom image, ~8-12 GB | ~¥1 | Saves ~30 min × ¥0.25/min = ¥7.5 per build |

In both cases, the warm artefact pays for itself after one build.

## When to NOT use the warm image

- **You're trying a one-off kernel or AOSP version.** If the build needs a fundamentally different OS, the warm image might be the wrong base. The setup script (and the warm image) pins to Ubuntu 22.04 LTS.
- **The warm image is too old.** If you haven't built in 6+ months, the image's AOSP build deps may be out of date. Either re-run the setup script (15 min) or build from a fresh stock image (30 min extra per build, but only once).
- **You're testing a build dep change.** Use a stock image and the new dep to confirm the change is correct, then re-bake the warm image.

## How the two providers differ

### DO: snapshot

- `doctl compute snapshot create <name> --droplet-id <id>` creates a snapshot from a powered-off droplet.
- Snapshots are stored in the same region as the droplet.
- Resolved by name on every build: `doctl compute snapshot list --region ... | awk '$2 == "qalos-build-warm"'`. Stateless.

### Aliyun: custom image

- `aliyun ecs CreateImage --RegionId ... --InstanceId ... --ImageName ...` creates a custom image from a stopped ECS.
- Custom images are region-scoped (not zone-scoped).
- Stored in `.pi/aliyun-state.json` because the image is referenced by ID, not by name. Stateful.

Both approaches are equivalent. The DO path is stateless because doctl resolves the snapshot by name; the Aliyun path is stateful because the API doesn't expose a "find image by name" call as cleanly.

## Setting up the warm image

```bash
# DO
.\tools\doctl-setup-base.ps1
#   ~10 min, ~$0.18 in droplet time + the ~$0.40/mo snapshot

# Aliyun
.\tools\aliyun-smoke-test.ps1                  # first, to bootstrap the VPC/SG/keypair
.\tools\aliyun-setup-base.ps1 -InstanceType ecs.u1-c1m8.2xlarge
#   ~15 min (smoke test) + ~15 min (setup-base) + ¥0.20 in ECS time + ¥1/mo image
```

**Always use the same instance type for the warm image as you plan to use for the build.** A warm image from a small instance may have a kernel or initramfs that doesn't suit a larger instance.

## What's next

- Want the four safety nets that prevent orphaned resources? → [Safety nets](safety-nets)
- Looking for the specific commands to set this up? → [DO build](../getting-started/do-build) or [Aliyun build](../getting-started/aliyun-build)
