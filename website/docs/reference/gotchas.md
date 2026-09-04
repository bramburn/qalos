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

## GCP

### `gcloud compute ssh` uses PuTTY/Plink on Windows and fails against modern Linux

**The hardcoded Plink path:** `C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\lib\googlecloudsdk\command_lib\util\ssh\ssh.py:206-210`. As of SDK 583.0.0 (core 2026.08.31) it's still PuTTY-on-Windows, hardcoded. Two symptoms, both reproducible:

1. **IAP tunneling fails**: `gcloud compute ssh --tunnel-through-iap ...` → Plink's TLS handshake to `tunnel.googleapis.com:443` is rejected with **"Remote side unexpectedly closed network connection"**. Affects Windows hosts behind corporate firewalls, TLS-inspection proxies, or where Plink's TLS version mismatch doesn't match the IAP proxy.
2. **Direct SSH fails against Debian 12 / OpenSSH 8.8+**: **"Server refused public-key signature despite accepting key! (server sent: publickey)"**. Plink 0.83's SHA-1 RSA signature isn't in the server's `PubkeyAcceptedAlgorithms`. Affects every modern Linux distro: Debian 12, Ubuntu 22.04+, RHEL 9, etc.

**Why the `gcp-*.ps1` scripts don't use `gcloud compute ssh`:** both errors above manifest in any gcloud-based SSH call. The orchestrator scripts (`gcp-smoke-test.ps1`, `gcp-setup-base.ps1`, `gcp-build.ps1`) instead call Windows OpenSSH directly:

```powershell
& 'C:\Windows\System32\OpenSSH\ssh.exe' -i "$env:USERPROFILE\.ssh\google_compute_engine" `
    -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL `
    "$env:USERNAME@<external-ip>" '<command>'
```

OpenSSH 9.5p2 (preinstalled on Windows 10 1809+ and Server 2019+) handles modern algorithms out of the box. Same for `scp.exe`.

**The proper long-term fix** is patching `ssh.py:206` to flip the `if platforms.OperatingSystem.IsWindows():` condition so OpenSSH is used even on Windows:

```diff
-    if platforms.OperatingSystem.IsWindows():
+    if platforms.OperatingSystem.IsWindows() and not os.environ.get('QALOS_GCP_USE_OPENSSH'):
       suite = Suite.PUTTY
       bin_path = _SdkHelperBin()
     else:
       suite = Suite.OPENSSH
       bin_path = None
```

The file lives in `C:\Program Files (x86)\` which is a protected path — needs PowerShell as admin to edit. If the patch is ever applied, all three `gcp-*.ps1` scripts can switch back to `gcloud compute ssh`/`gcloud compute scp` and drop the native OpenSSH helpers.

### PowerShell 5.1 wraps child-process stderr as `RemoteException`, corrupting `$LASTEXITCODE`

`gcloud.cmd` (the batch-file entry point) writes some informational messages to stderr. PowerShell 5.1's error stream treats any stderr output as a `RemoteException`, and the *first* stderr line sets `$LASTEXITCODE = 1` regardless of the actual child exit code. This affects `gcloud.cmd`, `gcloud.ps1`, and `python.exe` (when directly invoking `gcloud.py`).

**Reproduction:** `& gcloud.cmd compute instances list --format=json 2>&1` returns the right JSON on stdout but `$LASTEXITCODE = 1` because the warning "API [compute] is not enabled" goes to stderr.

**The workaround the qalos scripts use:** write a temporary batch file containing the full Python/gcloud.py invocation command, then invoke it via `Start-Process -NoNewWindow -Wait -PassThru`. The exit code is captured via `$proc.ExitCode` which is never corrupted. Stdout is redirected to a temp file. This is why the scripts have an `Invoke-Gcloud` helper wrapping every `gcloud.py` call instead of `& gcloud.cmd ...`.

### `gcloud compute instances list --format='value(name)'` does not work

The `value(...)` format requires a single field and only works on `describe`, not on `list`. Use `--format=json` and parse the JSON, or use `describe` and check for `NOT_FOUND` in the error message:

```powershell
$out = & gcloud compute instances describe $name --zone=$Zone --format=json
if ($out -match 'NOT_FOUND' -or $out -match 'was not found') { ... }
```

### `--format='value(status)'` in PowerShell double-quoted strings is a subexpression hazard

`--format=value(status)` inside a double-quoted PowerShell string is interpreted as `$(status)`, which runs `status` as a command. The build scripts use single quotes around the entire `--format='value(...)'` argument to avoid this.

### Spot preemption is real — use with a retry mindset

GCP Spot VMs can be reclaimed with **30-second preemption notice** (logged to the serial console). `repo sync` is resumable and `ccache` survives a reclaim. A mid-build preemption adds at most one extra `m` round. The on-host watchdog in `do-build.sh` will see the shutdown signal and clean up; the orchestrator's `try/finally` will delete the instance. Don't pay full price when Spot is 80%+ cheaper.

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
