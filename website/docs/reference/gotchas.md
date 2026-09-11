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

### `PublicEndpointForbidden` on cn-guangzhou public OSS (2026-09-11)

This Aliyun account has OSS data operations **blocked on the public endpoint** in `cn-guangzhou`. Bucket management (`mb`, `stat`, `get-acl`) works fine. `ossutil cp` and `ossutil ls` against any prefix fail with:

```
Error: operation error PutObject: Error returned by Service.
Http Status Code: 400.
Error Code: PublicEndpointForbidden.
Message: Not allowed using the OSS public endpoint, please use CNAME instead.
```

**Fix:** use **cn-hongkong** as the OSS staging region. HK's public endpoint is not blocked on this account, and intra-region HK OSS → HK ECS downloads are unmetered and 5–10× faster than public. Full pattern: [AOSP source migration to Aliyun](../getting-started/aosp-source-migration.md).

### UK → cn-guangzhou SSH is DPI-throttled to ~1 KB/s (2026-09-11)

Sustained high-volume SSH data transfer from a UK residential IP (e.g. `192.168.0.46`) to any `cn-guangzhou` ECS over port 22 is throttled to ~1–10 KB/s by what appears to be GFW DPI detection. TCP handshake works fine (0.26s), SSH auth works, but bulk data on port 22 is choked. At 1 KB/s, 35 GB takes 281 days.

**Symptom:** a 64-min rsync transferred 5.3 MB of 100 MB (~1.4 KB/s avg); a 5 MB scp test hung past the 120s timeout.

**Diagnosis:** looks like per-flow DPI throttling once SSH data is detected as sustained large. Per-connection, not total bandwidth — running 4 parallel rsyncs didn't increase throughput.

**Fix:** don't use port 22 / SSH for the bulk hop. Use HK OSS as the intermediate (see above). HTTPS uploads to HK OSS from UK are unthrottled, and downloads to HK ECS from the HK internal endpoint are unmetered and fast.

**Verification step before committing to any transfer:** run a 5 MB scp speed test first. If throughput is <100 KB/s, the path is unusable — pick a different intermediate (Cloudflare R2, Backblaze B2, GitHub Releases — anything on HTTPS port 443) or expect 30+ days.

### Aliyun OSS internal endpoint is 5–10× faster than public (2026-09-11)

When downloading large data **into** an Aliyun ECS, always use the `-internal` endpoint (`oss-cn-<region>-internal.aliyuncs.com`) instead of the public one. The internal endpoint is on Aliyun's private backbone:

- No internet egress charge for the download.
- 5–10× higher throughput because it doesn't traverse the public internet.
- No DPI throttling — port 443 between Aliyun ECS and OSS internal is unmetered.

Measured 2026-09-11 on cn-hongkong, downloading 35.5 GB across 339 files from the same OSS bucket:

| Endpoint | Throughput | Wall time |
| --- | --- | --- |
| `oss-cn-hongkong.aliyuncs.com` (public) | ~16 MB/s | ~37 min |
| `oss-cn-hongkong-internal.aliyuncs.com` (internal) | ~110 MB/s | ~5 min |

**Don't try to use `-internal` from outside Aliyun** — those endpoints are not publicly resolvable. For uploads from outside Aliyun, you have to use the public endpoint.

### ECS sizing for 100+ GB archive extraction (2026-09-11)

For extracting a zstd-compressed tarball of ~35 GB into a ~127 GB directory tree, **don't use `ecs.u1-c1m2.large` (2 vCPU / 2 GB RAM)**. The 2 GB RAM is too small — the OS swaps aggressively during the 127 GB write phase, and the I/O saturation makes SSH effectively unresponsive (every `du` or `ls -la` times out).

**What to use instead:**

- **For just downloading the source** (no extraction): `ecs.u1-c1m2.large` is fine — the bottleneck is network, not CPU/RAM.
- **For extracting and snapshotting the source**: at least `ecs.u1-c1m4.large` (4 vCPU / 8 GB RAM) — or 4 vCPU / 16 GB to be safe. The cat + zstd + tar phases are all single-process and memory-hungry, and 2 GB triggers constant swap.
- **For the actual build** (running `m -jN`): at least 64 GB RAM. 2 vCPU / 2 GB will not start soong bootstrap without OOMing.

### Three-phase extraction: `cat | zstd | tar`, not one pipe (2026-09-11)

When extracting a multi-volume zstd-compressed tarball like `aosp.zst.000` … `aosp.zst.338`, **always** split into three explicit phases with on-disk intermediates. Don't use a single pipe like `cat aosp.zst.* | zstd -d | tar -xf -`.

**Why:**

1. **Command-line length**: 339 filenames × ~12 chars = ~4 KB on the command line. Most shells handle this fine, but `tar -cf -` invoked via subprocess from another shell sometimes truncates at the first SIGPIPE. Explicit `cat aosp.zst.* > aosp.tar` is unambiguous.
2. **Debuggability**: each phase has a measurable output file. If phase 2 fails at 80%, you can resume from phase 2 without re-doing phase 1. With a single pipe, you restart from zero.
3. **Resource isolation**: phase 1 (cat) is I/O-bound, phase 2 (zstd) is CPU-bound (single-threaded, no `-T0`), phase 3 (tar) is I/O+metadata bound. A single pipe mixes all three so you can't tell which one is slow.
4. **Failure visibility**: if zstd errors with "invalid frame", you'll see it in phase 2's output. In a single pipe, the error appears at the tail of a 127 GB tar failure and is much harder to diagnose.

**Disk budget for the extraction:** 35 GB compressed + 35 GB intermediate tar + 127 GB decompressed + 127 GB extracted = 324 GB peak. A 300 GB disk will run out. Plan for ≥500 GB, or delete the compressed volumes after Phase 1.

Full recipe in [AOSP source migration to Aliyun](../getting-started/aosp-source-migration.md) § "Step 5: Extract the source".

### RAM user state traps (2026-09-11)

Two distinct failure modes both look like permission problems but need different fixes:

1. **`UserDisable` (HTTP 403, code `0003-00000801`) on `CreateBucket`** — the RAM user has policies attached but is **Disabled**. Fix: go to <https://ram.console.aliyun.com/users/aliyun-cli-user/identity> and click **Enable User**. (The "User Status" field is NOT in the Authentication sub-tab — it's on the user detail page Basic Information section or the Users list kebab menu.)

2. **`AccessDenied` (HTTP 403, code `Unauthorized`) on `ListBuckets` or other OSS ops** — the user is enabled but has no policy. Fix: attach the system policy `AliyunOSSFullAccess` to the user.

If you can `ossutil ls` (returns `Bucket Number is: 0`) but `ossutil mb` fails with `UserDisable`, you are in case (1), not case (2).

### Aliyun ECS outbound connectivity varies per zone (2026-09-10)

As of 2026-09-10, some `cn-hangzhou` zones have **zero outbound connectivity** — every `curl` returns `code=000` (connection refused, not 404). The instance has no default route to the internet gateway, or the security group is blocking all egress. `cn-hangzhou-i` was verified as zero-outbound on that date; `cn-hangzhou-j` had IPv6-only outbound.

**Don't assume "different zone = different policy = will work."** Egress policy can vary per zone within the same region.

**Fix for AOSP source:** don't rely on outbound connectivity from the Aliyun ECS at all. Use the [AOSP source migration to Aliyun](../getting-started/aosp-source-migration.md) pattern (Mac Mini → HK OSS → HK ECS), which sidesteps the closed-network problem entirely.

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

For safety, this PowerShell host blocks `Remove-Item -Recurse -Force` (it could irreversibly destroy files). Use the `trash` tool (or move files to a backup location) instead. This is intentional, not a bug.

### `cd dir && command` doesn't work

Use `Set-Location 'D:/qalos'` once, then run commands without `cd`. Or pass the workdir to specific tools that accept it. This is the PowerShell idiom; `cd` is an alias for `Set-Location` and doesn't persist across `&` invocations.

### Branch protection must be applied via the GitHub web UI or `gh api`

There's no in-repo file that enforces branch protection. You have to apply it once via the GitHub web UI or `gh api` (see [BRANCH_PROTECTION.md](https://github.com/bramburn/qalos/blob/main/BRANCH_PROTECTION.md) for the exact command). After that, the rules are persisted by GitHub.

### AOSP builds do NOT run on GitHub Actions

GH Actions free tier is 2000 min/month. A full AOSP build on `c-8` is 2-4 hours, on `c-16` is 1-2 hours. Even one build consumes 5-10% of the free tier, and 4 builds/month would blow it. The CI workflow on push is **static checks only**. AOSP builds happen locally or on the cloud fallbacks (which are the user's own resources, not GH Actions minutes).

## What's next

- Want the design rules these gotchas are exceptions to? → [Architecture overview](../architecture/overview.md)
- Want to add a new gotcha you just hit? → open a PR with a one-paragraph entry and the workaround. Update this page and AGENTS.md.
