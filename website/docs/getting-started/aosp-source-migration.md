---
sidebar_position: 5
---

# AOSP source migration to Aliyun

> **Read this before your first Aliyun build.** It documents the
> recipe proven on 2026-09-11 to ship a 35.5 GB compressed AOSP
> source tree from a UK home Linux box into a `cn-guangzhou` Aliyun
> ECS in ~2.5–3.5 hours total.

This page is the human-facing mirror of
[`AGENTS.md` §5.4.5](https://github.com/bramburn/qalos/blob/main/AGENTS.md).
Read that for the gotcha-level detail; this page is the recipe.

## Why this is not a `scp`

The naïve plan — `tar -cf - ~/aosp | ssh root@<ECS> tar -xf -` —
**does not work** in 2026-09-11 reality. Two reasons:

1. **UK → cn-guangzhou SSH is DPI-throttled to ~1 KB/s.** A 64-min
   rsync test transferred only 5.3 MB of 100 MB (~1.4 KB/s avg).
   At that rate, 35 GB takes 281 days. Parallel streams don't help
   — the throttle is per-flow. See
   [`AGENTS.md` §5.4.4](https://github.com/bramburn/qalos/blob/main/AGENTS.md).
2. **The cn-guangzhou public OSS endpoint is blocked at the account
   level** on this account. Symptom: `PublicEndpointForbidden`
   (HTTP 400, code `0048-00000401`). Bucket management (`mb`,
   `stat`) works; data ops (`cp`, `ls` against prefixes) fail. See
   [`AGENTS.md` §5.4.2](https://github.com/bramburn/qalos/blob/main/AGENTS.md).

The workaround uses **cn-hongkong** as a relay region: HK's public
OSS endpoint is not blocked, and intra-region HK OSS → HK ECS
downloads are unmetered and 5–10× faster than public.

## Topology

```
macmini2024 (UK, 192.168.0.46)
       │  ossutil cp via oss-cn-hongkong.aliyuncs.com (port 443)
       │  9.4 MiB/s avg, 60 min for 35.5 GB
       ▼
┌─────────────────────────────────────┐
│  HK OSS bucket qalos-aosp-hk        │
│  cn-hongkong (endpoint public OK)   │
└─────────────────────────────────────┘
       │  ossutil cp via oss-cn-hongkong-internal.aliyuncs.com
       │  109 MiB/s, 5 min for 35.5 GB  (intra-region, free)
       ▼
┌─────────────────────────────────────┐
│  HK ECS i-j6c13vpnkuq5dwj92rvc      │
│  cn-hongkong-d, 47.238.148.200      │
│  ecs.u1-c1m2.large, 300 GB disk     │
└─────────────────────────────────────┘
       │  cat aosp.zst.* | zstd -d | tar -xf -
       │  Extracts 35 GB → 127 GB AOSP source (~40-75 min on 2 vCPU)
       ▼
       StopInstance → CreateImage (custom image m-xxx in cn-hongkong)
       → CopyImage --DestinationRegionId cn-guangzhou (image m-yyy in cn-guangzhou)
       → RunInstances from m-yyy with ecs.u1-c1m8.2xlarge or larger
```

## Prerequisites

- A Linux/macOS machine with the AOSP source tree (the **sync
  host**). This is where `repo sync` runs to populate `~/aosp/`.
  Must have open internet (UK residential IPs are fine for
  `android.googlesource.com`).
- The Aliyun CLI installed and configured (see [Aliyun build](./aliyun-build.md)).
- The HK infra already bootstrapped: VPC, VSwitch, SG, KeyPair,
  OSS bucket. The `aliyun-smoke-test.{ps1,sh}` script creates
  all of these in cn-hongkong-d. The state file is at
  `D:\qalos\.pi\aliyun-state.json` (Windows) or
  `~/.pi/aliyun-state.json` (macOS/Linux). See
  [`tools/aliyun/AGENTS.md`](https://github.com/bramburn/qalos/blob/main/tools/aliyun/AGENTS.md).
- The AOSP source compressed and split into ≤100 MB volumes at
  `~/aosp_volumes/aosp.zst.000` … `aosp.zst.NNN`. Recipe below.

## Step 1: Compress the AOSP source on the sync host

The source tree is ~127 GB. Compress it with zstd at level 19
(near-maximum) and split into 100 MB volumes so each one fits in
an OSS multipart part. From `~/aosp/`:

```bash
cd ~/aosp
# -T0 = use all cores; --ultra -19 = maximum compression.
# 127 GB → ~35 GB compressed in ~45 min on 8 vCPU.
tar -cf - --exclude=./.repo --exclude=./out . \
  | zstd -T0 -19 --ultra -o /tmp/aosp.tar.zst

# Split into 100 MB parts for OSS multipart upload.
mkdir -p ~/aosp_volumes
split -b 100M /tmp/aosp.tar.zst ~/aosp_volumes/aosp.zst.
```

**Excludes:** `./.repo` is the `repo` tool's metadata (~5 GB and
unnecessary in the destination — the receiver will run
`repo init` itself) and `./out` is any prior build output.

Verify the parts:

```bash

# Expect: 339 files, 35.5 GB total
ls ~/aosp_volumes/ | wc -l
du -sh ~/aosp_volumes/
```

## Step 2: Upload to HK OSS (Mac Mini)

From the sync host (Mac Mini):

```bash

# 35.5 GB, 339 files, ~60 min at 9.4 MiB/s avg.
# --jobs 8 = parallel file uploads; --update = skip files
#           whose size+mtime already match the OSS object.
ossutil cp -r --jobs 8 --update ~/aosp_volumes/ \
    oss://qalos-aosp-hk/aosp-source/ \
    --endpoint oss-cn-hongkong.aliyuncs.com
```

The endpoint **must** be `oss-cn-hongkong.aliyuncs.com` (public),
not `oss-cn-hongkong-internal.aliyuncs.com` — the internal
endpoint is not resolvable from outside Aliyun.

**Verification before proceeding:**

```bash
ossutil ls oss://qalos-aosp-hk/aosp-source/ --endpoint oss-cn-hongkong.aliyuncs.com \
    | wc -l
# Expect: 339

ossutil du oss://qalos-aosp-hk/aosp-source/ --endpoint oss-cn-hongkong.aliyuncs.com
# Expect: ~35.5 GB
```

## Step 3: Spin up a small HK ECS receiver

A 2 vCPU / 2 GB RAM / 300 GB disk ECS in `cn-hongkong-d` is enough
for the download (network-bound). It's **undersized** for the
extraction phase (see Step 5 and
[Gotchas](../reference/gotchas.md) § "ECS sizing for extraction"),
but it's cheap (~$0.015/hr spot) and disposable.

```powershell

# Windows (PowerShell)
$ecs = aliyun ecs RunInstances --RegionId cn-hongkong `
    --ImageId ubuntu_24_04_x64_20G_alibase_<YYYYMMDD>.vhd `
    --InstanceType ecs.u1-c1m2.large `
    --VSwitchId vsw-j6c1rnm4bhqkyc8ylp2go `
    --SecurityGroupId sg-j6c2f71haqscua7ecg2l `
    --KeyPairName qalos-aosp-key-ed25519 `
    --InstanceChargeType PostPaid `
    --InternetChargeType PayByTraffic --InternetMaxBandwidthOut 100 `
    --SystemDisk.Category cloud_essd --SystemDisk.Size 300

# macOS/Linux
ecs=$(aliyun ecs RunInstances --RegionId cn-hongkong \
    --ImageId ubuntu_24_04_x64_20G_alibase_<YYYYMMDD>.vhd \
    --InstanceType ecs.u1-c1m2.large \
    --VSwitchId vsw-j6c1rnm4bhqkyc8ylp2go \
    --SecurityGroupId sg-j6c2f71haqscua7ecg2l \
    --KeyPairName qalos-aosp-key-ed25519 \
    --InstanceChargeType PostPaid \
    --InternetChargeType PayByTraffic --InternetMaxBandwidthOut 100 \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 300)
```

Then:

```bash
# Resize online may fail — stop, resize, start.
aliyun ecs StopInstance --RegionId cn-hongkong --InstanceId <ECS_ID>
# (skip if disk is already 300 GB)
aliyun ecs ResizeDisk --RegionId cn-hongkong --InstanceId <ECS_ID> \
    --Type online | offline --Size 300
aliyun ecs StartInstance --RegionId cn-hongkong --InstanceId <ECS_ID>

# Once Running, find the public IP and SSH in.
aliyun ecs DescribeInstances --RegionId cn-hongkong --InstanceIds '["<ECS_ID>"]' \
    | grep -E "PublicIpAddress|IpAddress"

# SSH key is the ed25519 qalos key you generated earlier.
ssh -i ~/.ssh/id_ed25519_qalos root@<ECS_IP>

# On the ECS: expand the partition (resize2fs after growpart).
growpart /dev/vda 3
resize2fs /dev/vda3
```

## Step 4: Download from HK OSS to HK ECS (fast)

From inside the HK ECS:

```bash
# Install ossutil v2.4.0
curl -O https://gosspublic.alicdn.com/ossutil/2.4.0/ossutil64
chmod +x ossutil64
mv ossutil64 /usr/local/bin/ossutil

# Configure for the HK region with the SAME AccessKey as your local machine.
ossutil config \
    --endpoint oss-cn-hongkong-internal.aliyuncs.com \
    --access-key-id <AK> \
    --access-key-secret <SK>

# Download — uses the INTERNAL endpoint, which is 5-10x faster
# than public AND free (no egress).
# 35.5 GB, 339 files, ~5 min at 110 MiB/s.
mkdir -p /aosp
ossutil cp -r --jobs 8 --update \
    oss://qalos-aosp-hk/aosp-source/ \
    /aosp/ \
    --endpoint oss-cn-hongkong-internal.aliyuncs.com
```

**Why the internal endpoint matters here:** see
[`AGENTS.md` §7.8](https://github.com/bramburn/qalos/blob/main/AGENTS.md)
— the `-internal` variant is on Aliyun's private backbone, so it's
unmetered, fast, and not subject to GFW DPI throttling.

## Step 5: Extract the source

Three phases, not one pipe (see
[`AGENTS.md` §7.10](https://github.com/bramburn/qalos/blob/main/AGENTS.md)
for why):

```bash
echo "=== Phase 1: concatenate ===" && date
cat /aosp/aosp.zst.000 /aosp/aosp.zst.001 ... /aosp/aosp.zst.338 > /aosp/aosp.tar
echo "=== Phase 1 done ===" && date && ls -la /aosp/aosp.tar
# ~12 min on 2 vCPU

echo "=== Phase 2: zstd decompress ===" && date
zstd -d /aosp/aosp.tar -o /aosp/aosp.tar.raw
echo "=== Phase 2 done ===" && date && ls -la /aosp/aosp.tar.raw
# 30-60 min on 2 vCPU (single-threaded, no -T0 because RAM is tight)

echo "=== Phase 3: tar extract ===" && date
mkdir -p /aosp-extracted
tar -xf /aosp/aosp.tar.raw -C /aosp-extracted/
echo "=== Phase 3 done ===" && date && du -sh /aosp-extracted/
# 5-10 min on 2 vCPU

# Clean up intermediates before snapshot (saves 162 GB).
rm /aosp/aosp.tar /aosp/aosp.tar.raw /aosp/aosp.zst.*
```

**Disk budget for the extraction:** 35 GB compressed + 35 GB
intermediate tar + 127 GB decompressed + 127 GB extracted = 324 GB
peak. A 300 GB disk will run out. Plan for ≥500 GB, or delete the
compressed volumes after Phase 1.

**The 2 vCPU / 2 GB ECS is undersized for this phase.** You'll see
heavy swap and SSH will periodically time out during the cat
phase. Don't panic — just wait and retry. If you have to redo
this often, upgrade to `ecs.u1-c1m4.large` (4 vCPU / 8 GB) — see
[`AGENTS.md` §7.9](https://github.com/bramburn/qalos/blob/main/AGENTS.md).

## Step 6: Snapshot the HK ECS into a custom image

```bash

# Stop the instance first (image creation requires Stopped).
aliyun ecs StopInstance --RegionId cn-hongkong --InstanceId <ECS_ID>

# Wait until Status == Stopped.
aliyun ecs DescribeInstances --RegionId cn-hongkong \
    --InstanceIds '["<ECS_ID>"]' | grep -E "Status|Stopped"

# Create the image. This snapshot the system disk (with /aosp-extracted
# already populated) into a custom image. ~10-30 min.
aliyun ecs CreateImage --RegionId cn-hongkong \
    --InstanceId <ECS_ID> \
    --ImageName qalos-aosp-base-v1 \
    --Description "AOSP 15.0.0_r1 source tree, ready for build"

# Returns an ImageId (m-xxxxxxxxxxxxx). Note it.
```

## Step 7: Copy the image to cn-guangzhou

```bash

# Intra-Aliyun copy; ~10-30 min, no egress charge.
aliyun ecs CopyImage --RegionId cn-hongkong \
    --ImageId <HK_IMAGE_ID> \
    --DestinationRegionId cn-guangzhou \
    --DestinationImageName qalos-aosp-base-v1

# Returns a destination ImageId in cn-guangzhou (m-yyyyyyyyyyyyy).
# Note it — you need it for Step 8.
```

## Step 8: Launch the build VM from the copied image

```bash

# Production build VM in cn-guangzhou.
# ecs.u1-c1m8.2xlarge = 8 vCPU / 64 GB, AOSP-minimum spec.
# Spot pricing ~¥7/6h.
# System disk 500 GB — AOSP out/ artifacts can be 50+ GB.
aliyun ecs RunInstances --RegionId cn-guangzhou \
    --ImageId <GZ_IMAGE_ID> \
    --InstanceType ecs.u1-c1m8.2xlarge \
    --InstanceChargeType PostPaid --SpotStrategy SpotAsPriceGo \
    --VSwitchId vsw-7xvvy64syomut0vdu6iin \
    --SecurityGroupId sg-7xv0xvsywi6cm82ea65c \
    --KeyPairName qalos-aosp-key-ed25519 \
    --SystemDisk.Category cloud_essd --SystemDisk.Size 500
```

Once this VM is running, follow the **Aliyun build** flow (see
[Aliyun build](./aliyun-build.md) § "Per-build") to run
`do-build.sh` on it via `systemd-run`, set up the `mavis cron`
monitor, and download the artifacts via HTTP.

## Timing summary

| Phase | Throughput | Wall time for 35.5 GB → 127 GB |
| --- | --- | --- |
| Mac Mini → HK OSS (public) | 9.4 MiB/s | 60 min |
| HK OSS → HK ECS (internal) | 109 MiB/s | 5 min |
| HK ECS: cat 339 volumes | ~50 MB/s | 12 min |
| HK ECS: zstd decompress | single-threaded | 30–60 min |
| HK ECS: tar extract | disk-bound | 5–10 min |
| CreateImage + CopyImage | Aliyun API | 10–30 min |
| **Total** | | **~2.5–3.5 hours** |

## Cleanup

Once the build VM is running successfully:

```bash

# Delete the HK OSS objects (saves ~¥1/month storage).
ossutil rm --recursive --force \
    oss://qalos-aosp-hk/aosp-source/ \
    --endpoint oss-cn-hongkong-internal.aliyuncs.com

# Release the HK ECS (saves ~$0.015/hr idle).
aliyun ecs DeleteInstance --RegionId cn-hongkong --InstanceId <ECS_ID>

# The HK custom image (qalos-aosp-base-v1) — KEEP.
# It's the unit of cost optimization: ~¥8-12/month, saves 2-3 hours
# of source upload on every subsequent build VM launch.
# Only delete it if you're sure you'll never need it again.
```

On the sync host (Mac Mini):

```bash

# Remove the 35 GB staging dir.
rm -rf ~/aosp_volumes

# Remove the local compressed tar (only after the build VM verified
# /aosp-extracted is healthy and contains the expected files).
rm /tmp/aosp.tar.zst
```

## What if Step 2 fails mid-upload?

The OSS multipart upload is resumable per file. Just re-run the
same `ossutil cp -r --update ...` command. `--update` skips files
whose size+mtime already match, so only the in-progress file gets
re-uploaded.

For a truly failed-in-the-middle file, the partial object lives
at `oss://qalos-aosp-hk/aosp-source/<name>` and gets overwritten
on the next `--update` attempt. No manual cleanup needed.

## What's next

- Ready to build? → [Aliyun build](./aliyun-build.md) § "Per-build"
- Hit a gotcha? → [Gotchas](../reference/gotchas.md) — especially §
  "ECS sizing for extraction" and § "Aliyun OSS internal endpoint
  is 5–10× faster than public"
- Need the recipe in script form? →
  [`tools/aliyun/AGENTS.md`](https://github.com/bramburn/qalos/blob/main/tools/aliyun/AGENTS.md)
  is the LLM-driven runbook; the smoke-test and setup-base scripts
  are kept on disk for users who prefer scripts.
