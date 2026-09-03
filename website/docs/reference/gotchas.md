---
sidebar_position: 4
---

# Gotchas

The sharp edges that cost us time, and the workarounds. Documented so the next person doesn't re-discover them.

## Aliyun

### `DescribeInstanceTypes` returns the catalog, not the stock

`DescribeInstanceTypes` lists every instance type Aliyun has ever sold. It does **not** tell you which ones are purchasable in your zone. `ecs.t5-lc1m1.small` shows in the catalog. That doesn't mean it's purchasable in `cn-hangzhou-h`.

**Fix:** use `DescribeAvailableResource --DestinationResource InstanceType` to check actual stock. T5 burstable instances are particularly zone-limited.

```bash
aliyun ecs DescribeAvailableResource \
    --RegionId cn-hangzhou \
    --ZoneId cn-hangzhou-h \
    --DestinationResource InstanceType
```

### `--InstanceType` on `DescribeAvailableResource` is unreliable as a filter

Passing `--InstanceType '["ecs.t5-..."]'` to `DescribeAvailableResource` silently returns empty results. Drop the filter, get the full in-stock list, then filter in PowerShell/bash.

### `DeleteInstance` on a `Running` instance can return `SDK.ServerError`

Reproduced ~50% of the time on the first call after `RunInstances`.

**Fix:** always `StopInstance` first, wait for `Stopped`, then `DeleteInstance`. The script does this in the `finally{}` block.

```bash
aliyun ecs StopInstance --InstanceId "$ID"
# wait for Status == Stopped
aliyun ecs DeleteInstance --InstanceId "$ID" --Force true
```

### New accounts have a `RunInstances` rate limit

First account, first day: you get 1-2 `RunInstances` per minute, then throttling kicks in. If you see a hang on `RunInstances` followed by `SDK.ServerError`, you've been throttled. Wait 60-90 s and retry. The `aliyon()` helper in the scripts already retries 4 times with backoff.

### RAM warnings: 0.5 GB instances may not boot Ubuntu

The smoke test can pick `ecs.e-c2m1.small` (1 vCPU / 0.5 GB) as the "smallest in-stock" — it satisfies the `Sort-Object MemorySize, CpuCoreCount` heuristic. But Ubuntu 22.04 needs ~600 MB just to boot. If the instance hangs in `Pending` for >2 min, the type is too small.

**Fix:** the smoke test retries on the next-smallest in-stock type, but this isn't perfect. For the real build, never go below 2 GB.

### The `aliyun` CLI suppresses error details

`aliyun` on Windows prints `ERROR: SDK.ServerError` and nothing else. No request id, no error code, no remediation.

**Fix:** parse stdout (which is JSON), never trust the bare stderr. The `aliyon()` helper in every script handles this. If you need to see the actual error, redirect to a file:

```powershell
& $aliyun ecs RunInstances @args *>&1 | Tee-Object -FilePath $logFile
```

### PowerShell quoting of JMESPath

`aliyun --cli-query 'foo'` is great in bash. In PowerShell, single quotes inside a single-quoted string are awkward, and the resulting `2>&1 | ConvertFrom-Json` flow is fragile.

**Fix:** the scripts in this repo use plain JSON output + `ConvertFrom-Json` in PowerShell. The performance cost is negligible (kilobytes of JSON).

### The on-host upload step in `do-build.sh` targets DO Spaces

`do-build.sh` uploads artifacts to DO Spaces. This is wrong for the Aliyun path (you're on Aliyun, not DO). For now, the Aliyun orchestrator pulls artifacts via `scp` instead — it incurs egress cost from `cn-hangzhou` to the UK (~¥0.12/GB).

**The clean fix** is to parameterise the upload step in `do-build.sh` with a `BUILD_UPLOAD_BACKEND=scp|spaces|oss|none` env var. Not done in this commit because it's a refactor of an existing working script. Tracked in the AGENTS.md "Known limitations" section.

## DigitalOcean

### Snapshot creation requires a powered-off droplet

DO prefers the droplet to be off when you snapshot. If you skip the `shutdown -h now` step in `doctl-setup-base.ps1`, the snapshot still works but is more likely to be inconsistent (in-flight writes not flushed).

**Fix:** the script powers off the base droplet before snapshotting and waits for `Status == off` before calling `doctl compute snapshot create`.

### `doctl compute droplet create --wait` is slow

`--wait` blocks until the droplet reaches an active state, but "active" doesn't mean "SSH-ready". The script uses `--wait` then a separate `ssh -o ConnectTimeout=5 ...` loop to confirm SSH is actually up.

### The warm snapshot is region-scoped

DO snapshots live in the region they were created in. If you create the snapshot in `lon1` and try to use it in `nyc3`, you'll get a not-found error. The script defaults to `lon1` (the region you set up the snapshot in) and the build script reads the same default.

## General

### `Remove-Item -Recurse -Force` is blocked by the shell

For safety, this PowerShell host blocks `Remove-Item -Recurse -Force` (it could irreversibly destroy files). Use the [trash tool](#) instead, or move files to a backup location. This is intentional, not a bug.

### `cd dir && command` doesn't work

Use `Set-Location 'D:/qalos'` once, then run commands without `cd`. Or pass the workdir to specific tools that accept it. This is the PowerShell idiom; `cd` is an alias for `Set-Location` and doesn't persist across `&` invocations.

### Branch protection must be applied via the GitHub web UI or `gh api`

There's no in-repo file that enforces branch protection. You have to apply it once via the GitHub web UI or `gh api` (see [BRANCH_PROTECTION.md](https://github.com/bramburn/qalos/blob/main/BRANCH_PROTECTION.md) for the exact command). After that, the rules are persisted by GitHub.

### AOSP builds do NOT run on GitHub Actions

GH Actions free tier is 2000 min/month. A full AOSP build on `c-8` is 2-4 hours, on `c-16` is 1-2 hours. Even one build consumes 5-10% of the free tier, and 4 builds/month would blow it. The CI workflow on push is **static checks only**. AOSP builds happen locally or on the cloud fallbacks (which are the user's own resources, not GH Actions minutes).

## What's next

- Want the design rules these gotchas are exceptions to? → [Architecture overview](../architecture/overview)
- Want to add a new gotcha you just hit? → open a PR with a one-paragraph entry and the workaround. Update this page and AGENTS.md.
