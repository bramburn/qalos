---
sidebar_position: 3
---

# DigitalOcean build (fallback #1)

The clean-room CI path. Picks up when your local box is unavailable, or when you need a build that proves nothing on your local machine is influencing the result. The DO scripts are the **most battle-tested** of the cloud paths — they have all four safety nets in production.

## Prerequisites

- A DigitalOcean account.
- A DigitalOcean API token (read+write) at https://cloud.digitalocean.com/account/api/tokens/new
- An SSH key registered with DigitalOcean (https://cloud.digitalocean.com/account/security)
- A Windows / macOS / Linux machine to run the orchestrator from.

## One-time setup (~10 min)

From the repo root:

```powershell
# 1. Install doctl (DigitalOcean CLI)
.\tools\doctl-install.ps1

# 2. Set the API token
$env:DO_API_TOKEN = '<your-read-write-token>'

# 3. Create the base droplet + warm snapshot
.\tools\doctl-setup-base.ps1
```

The setup script:
1. Spins up a fresh c-8 (8 vCPU / 16 GB) droplet from the stock Ubuntu 22.04 image.
2. Runs `tools/setup-droplet.sh` to install every AOSP build dependency.
3. Snapshots the result as `qalos-build-warm` (~3-4 GB).
4. Deletes the base droplet.

The snapshot is the artefact you keep. Every subsequent build launches from it, skipping the 30-min `apt install`.

## Per-build (~2-4 h)

```powershell
.\tools\doctl-build.ps1
# or with overrides:
.\tools\doctl-build.ps1 -DropletSize c-16 -BuildVariant eng -MaxRuntimeMinutes 360
```

The build script:
1. Creates a droplet from the `qalos-build-warm` snapshot.
2. Waits for SSH.
3. Scp's `tools/do-build.sh` onto it.
4. Runs the build (this is the long part — 1-6 hours depending on droplet size).
5. Uploads the resulting `*.img` files to DO Spaces.
6. Destroys the droplet — no matter what.

## Standing cost

| Item | Cost |
| --- | --- |
| `qalos-build-warm` snapshot | ~$0.40/month |
| DO Spaces (storage for build artifacts) | $5/month (first 250 GB) |
| **Total if you maintain the fallback** | **~$5.40/month** |

If you only build occasionally, you can drop the snapshot and accept the 30 min re-setup cost the next time you need it. See [Tools reference](../reference/tools-reference) for `doctl-snapshot-delete.ps1` (coming soon) or the manual console steps.

## When to pick DO over Aliyun

- **You're in Europe or the US.** DO has UK / US / EU regions; latency is low.
- **You need a battle-tested setup.** The DO scripts have been running since 2026-09; the Aliyun scripts are newer and have the documented gotchas in [Gotchas](../reference/gotchas).
- **You don't need China-region access.** AOSP's Tsinghua TUNA mirror is fast from China; not so much from Europe.

## What's next

- Want a China-region build? → [Aliyun build](aliyun-build)
- Want to understand the four safety nets? → [Safety nets](../architecture/safety-nets)
- Want to see the build in action on GitHub? → push to `main` or click **Run workflow** in the Actions tab. The DO build is triggered by `.github/workflows/build.yml`.
