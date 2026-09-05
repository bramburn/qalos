---
sidebar_position: 13
---

# Manual agent-driven build via shell access

The `tools/gcp-*.ps1`, `tools/aliyun-*.ps1`, and `tools/doctl-*.ps1` orchestrators are **convenience wrappers** around the same underlying primitives. When they're too rigid, broken, or unavailable, an LLM agent can drive the full build directly from a Windows PowerShell or Linux/macOS bash shell. This page documents the manual flow.

## Why this exists

The orchestrator scripts (a) assume a particular Windows PowerShell 5.1+ host, (b) wrap each gcloud CLI / `gcloud compute ssh` call in a JSON-batch-file + `Start-Process` pattern to avoid PowerShell's stderr-as-`RemoteException` corruption, and (c) bind to a specific instance type, region, and SSH key. If any of those assumptions break (e.g. a new gcloud SDK changes the SSH wrapper, the user runs Linux/macOS, or the user wants a custom instance type the script doesn't expose), the manual flow is the fallback.

The on-host build (`tools/do-build.sh`) is identical across all paths. Only the orchestrator that **launches** the cloud instance and **exchanges** artefacts with it differs.

## Manual GCP build (10 steps, ~5 min of typing + 1-6 h of build)

All commands are PowerShell 5.1+. Linux/macOS uses bash with `gcloud` / `ssh` / `scp` in place of the Start-Process wrappers. The first three steps are one-time per project.

### 0. One-time per project

```powershell
# Verify gcloud is authenticated and a project is set
gcloud auth list --format="value(account)"
gcloud config get-value project

# Make sure SSH key is in project metadata. If you haven't run
# `gcloud compute ssh` before, this generates the key.
$key = "$env:USERPROFILE\.ssh\google_compute_engine"
if (-not (Test-Path $key)) {
    gcloud compute ssh --dry-run 2>&1 | Out-Null   # generates $key
}
```

### 1. Create the warm snapshot (only the first time)

The snapshot is a disk image with all AOSP build dependencies pre-installed. After this, every build reuses the snapshot and skips the ~5-10 min `apt install` step.

```powershell
$zone = 'us-central1-a'
$base = 'qalos-base'
$baseDisk = 200
$snap = 'qalos-build-warm'

# Create the base instance, run setup-droplet.sh, snapshot the disk, delete the base
gcloud compute instances create $base `
    --zone=$zone `
    --machine-type=e2-medium `
    --image-family=debian-12 `
    --image-project=debian-cloud `
    --boot-disk-size=$baseDisk `
    --boot-disk-type=pd-standard `
    --format=json

# Wait for RUNNING + get external IP + SCP setup-droplet.sh + run it via sudo
# (See step 5 below for the SSH/SCP pattern — same calls apply here.)

# Stop, snapshot, delete
gcloud compute instances stop $base --zone=$zone
gcloud compute snapshots create $snap --source-disk=$base --source-disk-zone=$zone
gcloud compute instances delete $base --zone=$zone --quiet
```

### 2. Save state

```powershell
$state = [pscustomobject]@{
    snapshotName = $snap
    project      = (gcloud config get-value project)
    zone         = $zone
    sshKey       = $key
    sshUser      = $env:USERNAME
    updatedAt    = (Get-Date).ToString('o')
}
$state | ConvertTo-Json | Set-Content .\.pi\gcp-state.json
```

### 3. Launch the build instance from the snapshot

```powershell
$build = "qalos-build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
$type  = 'c3d-highcpu-16'    # 16 vCPU / 32 GB. Use c3d-standard-16 if OOMs.
$disk  = 500
$maxMin = 360

gcloud compute instances create $build `
    --zone=$zone `
    --machine-type=$type `
    --provisioning-model=SPOT `
    --max-run-duration="${maxMin}m" `
    --source-snapshot=$snap `
    --boot-disk-size=$disk `
    --boot-disk-type=pd-ssd `
    --no-service-account `
    --no-scopes `
    --format=json
```

### 4. Wait for RUNNING and get the external IP

```powershell
do {
    Start-Sleep -Seconds 5
    $status = (gcloud compute instances describe $build --zone=$zone --format='value(status)' 2>&1).Trim()
} while ($status -ne 'RUNNING')

$extIp = (gcloud compute instances describe $build --zone=$zone --format='value(networkInterfaces[0].accessConfigs[0].natIP)' 2>&1).Trim()
Write-Host "External IP: $extIp"
```

### 5. SSH / SCP wrappers

The gcloud SDK on Windows hardcodes PuTTY/Plink, which fails against Debian 12 / OpenSSH 8.8+ and against the IAP proxy TLS. Use Windows OpenSSH directly:

```powershell
$sshExe  = 'C:\Windows\System32\OpenSSH\ssh.exe'
$scpExe  = 'C:\Windows\System32\OpenSSH\scp.exe'
$extIp  = '<from step 4>'

# Generic SSH helper. Returns @{ code; out; err }.
function Invoke-Ssh {
    param([string]$Ip, [string]$Command)
    $out = "$env:TEMP\qalos-ssh-$(Get-Random).out"
    $err = "$env:TEMP\qalos-ssh-$(Get-Random).err"
    $args = @(
        '-i', "$env:USERPROFILE\.ssh\google_compute_engine",
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR',
        "$env:USERNAME@${Ip}", $Command
    )
    $proc = Start-Process -FilePath $sshExe -ArgumentList $args -NoNewWindow -Wait -PassThru `
        -RedirectStandardOutput $out -RedirectStandardError $err
    return @{
        code = $proc.ExitCode
        out  = if (Test-Path $out) { Get-Content $out -Raw } else { '' }
        err  = if (Test-Path $err) { Get-Content $err -Raw } else { '' }
    }
}

function Invoke-ScpUpload {
    param([string]$Local, [string]$Ip, [string]$Remote)
    $args = @(
        '-i', "$env:USERPROFILE\.ssh\google_compute_engine",
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR',
        $Local, "$env:USERNAME@${Ip}:${Remote}"
    )
    (Start-Process -FilePath $scpExe -ArgumentList $args -NoNewWindow -Wait -PassThru).ExitCode
}

function Invoke-ScpDownload {
    param([string]$Ip, [string]$Remote, [string]$Local)
    $args = @(
        '-i', "$env:USERPROFILE\.ssh\google_compute_engine",
        '-o', 'StrictHostKeyChecking=no', '-o', 'UserKnownHostsFile=NUL', '-o', 'LogLevel=ERROR',
        "$env:USERNAME@${Ip}:${Remote}", $Local
    )
    (Start-Process -FilePath $scpExe -ArgumentList $args -NoNewWindow -Wait -PassThru).ExitCode
}
```

### 6. Wait for SSH

```powershell
for ($i = 0; $i -lt 30; $i++) {
    $r = Invoke-Ssh -Ip $extIp -Command 'echo ready'
    if ($r.code -eq 0) { break }
    Start-Sleep -Seconds 5
}
```

### 7. SCP the build script and env file, then run

```powershell
# Write the env file. PowerShell 5.1 doesn't support utf8NoBOM, so use ascii
# (the env file is pure ASCII bash).
$envFile = "$env:TEMP\qalos-env.sh"
@"
QALOS_REPO_URL='https://github.com/bramburn/qalos.git'
AOSP_TAG='android-15.0.0_r1'
BUILD_TARGET='qalos_emulator'
BUILD_VARIANT='userdebug'
MAX_RUNTIME_MINUTES='$maxMin'
SPACES_BUCKET=''
SPACES_REGION=''
SPACES_KEY=''
SPACES_SECRET=''
"@ | Out-File -FilePath $envFile -Encoding ascii -NoNewline

# Upload
[void](Invoke-ScpUpload -Local (Resolve-Path $envFile) -Ip $extIp -Remote '/tmp/qalos-env.sh')
[void](Invoke-ScpUpload -Local (Resolve-Path .\tools\do-build.sh) -Ip $extIp -Remote '/tmp/do-build.sh')

# IMPORTANT: `sudo` strips env vars by default. The build script needs the
# env vars, so we source the env file inside the sudo subshell with -E.
$buildResult = Invoke-Ssh -Ip $extIp -Command "sudo -E bash -c 'source /tmp/qalos-env.sh; bash /tmp/do-build.sh'"
```

### 8. Pull artifacts back via SCP

```powershell
$outDir = ".\.pi\out\gcp-build\$build"
New-Item -ItemType Directory -Path "$outDir\images" -Force | Out-Null

foreach ($img in 'system.img','boot.img','userdata.img','vendor.img','product.img') {
    $r = Invoke-Ssh -Ip $extIp -Command "test -f /root/aosp/out/target/product/qalos_emulator/$img && echo EXISTS || echo MISSING"
    if ($r.out -match 'EXISTS') {
        [void](Invoke-ScpDownload -Ip $extIp -Remote "/root/aosp/out/target/product/qalos_emulator/$img" -Local "$outDir\images\$img")
    }
}
[void](Invoke-ScpDownload -Ip $extIp -Remote '/root/aosp/.qalos-logs/build.log' -Local "$outDir\build.log")
```

### 9. Cleanup — always destroy the instance

Even on Ctrl+C, hard kill, or uncaught exception. The four-safety-net pattern still applies; without the orchestrator's `try/finally`, the agent must do this manually.

```powershell
gcloud compute instances stop   $build --zone=$zone
# wait for TERMINATED
gcloud compute instances delete $build --zone=$zone --quiet
# verify
$still = (gcloud compute instances describe $build --zone=$zone --format='value(name)' 2>&1).Trim()
if ($still -and $still -notmatch 'NOT_FOUND|was not found') {
    Write-Warning "INSTANCE $build STILL ALIVE. Manually delete: gcloud compute instances delete $build --zone=$zone"
}
```

## Linux / macOS equivalent

The same flow, but with the SSH/SCP wrappers being direct `ssh`/`scp` calls:

```bash
ssh -i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL \
    "$USER@$EXT_IP" 'echo ready'

scp -i ~/.ssh/google_compute_engine ./qalos-env.sh "$USER@$EXT_IP:/tmp/qalos-env.sh"
scp -i ~/.ssh/google_compute_engine ./tools/do-build.sh "$USER@$EXT_IP:/tmp/do-build.sh"

ssh -i ~/.ssh/google_compute_engine -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL \
    "$USER@$EXT_IP" "sudo -E bash -c 'source /tmp/qalos-env.sh; bash /tmp/do-build.sh'"
```

`sudo -E` is the critical bit — without it, the env vars don't make it to the root subshell that actually runs the build. (This is the same bug the orchestrator script hits; if you ever script the manual flow, propagate env via `sudo -E` or set them in `/etc/environment`.)

## Safety nets — still required

Even doing it manually, you need the same four safety nets the orchestrator enforces:

1. **Parent-process watchdog** — if the agent / shell dies, the instance must be deleted. Either:
   - Run the build under a wrapper that polls and tears down on parent death, OR
   - Set `--max-run-duration=360m` on the Spot instance (GCP guarantees teardown at this point).
2. **On-host watchdog** — `do-build.sh` already has one. It force-shuts-down the VM at `MAX_RUNTIME_MINUTES` elapsed. Don't disable it.
3. **`try/finally` around the SSH** — in a script, the `finally` calls `gcloud compute instances delete`. In an interactive shell, manually `gcloud compute instances delete` before exiting.
4. **Final describe check** — after `delete`, call `gcloud compute instances describe` and verify it returns `NOT_FOUND`. If it doesn't, retry.

## Debugging a stuck build

The build is `repo sync | tee repo-sync.log && m -j16 | tee build.log`. Both logs are in `~/aosp/.qalos-logs/` on the instance. To watch:

```powershell
Invoke-Ssh -Ip $extIp -Command 'tail -f /root/aosp/.qalos-logs/build.log'
```

The most common failure modes:

- **`repo sync` network errors** — AOSP git servers (`android.googlesource.com`) are sometimes blocked / slow from cloud regions. Either wait and retry, or pre-fetch the source on a host that can reach AOSP and upload the `.repo` and projects.
- **Java heap OOM** — AOSP Java compile needs ~4 GB heap. If it dies with `OutOfMemoryError`, switch from `c3d-highcpu-16` (32 GB) to `c3d-standard-16` (64 GB). Don't try to add swap; AOSP ignores it.
- **Spot preemption** — 30-second preemption notice. `repo sync` is resumable; `ccache` is on the persistent disk. Just relaunch from the snapshot.
- **Disk full** — AOSP source is ~80 GB, build output is another ~100 GB. The 500 GB default disk is enough but tight. Bump to 800 GB if you see `No space left on device`.

## When to use the manual flow vs the orchestrator

| Use orchestrator when | Use manual flow when |
|---|---|
| You trust the .ps1 scripts and the four safety nets | You want a custom instance type / region the script doesn't expose |
| You want a one-liner that creates the snapshot, builds, and cleans up | The orchestrator has a bug you don't want to debug right now |
| You're following the same pattern as the existing `doctl-*.ps1` and `aliyun-*.ps1` | You're an LLM agent running in a sandboxed environment without write access to the script files |
| You want a quick smoke test or a CI integration | You want fine-grained control over the SSH commands (e.g. capture live progress, inject custom steps) |
