# qalos-launch.ps1 - launch a GCP build using the corrected systemd-run pattern
#
# Bypasses the gcp-build.ps1 SSH-shutdown bug by:
# 1. Creating the instance from the warm snapshot
# 2. Uploading do-build.sh
# 3. Launching the build via systemd-run (DETACHED) on the instance
# 4. Returning immediately with the instance name + IP
#
# The LLM monitor cron (created separately) owns the cleanup.
# See AGENTS.md section 2.8 and the gcp-build.ps1 SSH-shutdown warning.

$ErrorActionPreference = 'Stop'

$gcloudPython = 'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\platform\bundledpython\python.exe'
$gcloudScript = 'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\lib\gcloud.py'
$env:PYTHONUTF8 = '1'
$sshExe = 'C:\Windows\System32\OpenSSH\ssh.exe'
$scpExe = 'C:\Windows\System32\OpenSSH\scp.exe'
$sshKey = "$env:USERPROFILE\.ssh\google_compute_engine"

$Zone = 'us-east1-b'
# c3d-highmem-16: 16 vCPU / 128 GB / ~$0.30/hr Spot. Same type as
# the prior 5h54m-to-69% run (qalos-build-20260905-000541), which
# extrapolates to ~8.5h for a full build. The user's quota caps
# (CPUS_PER_VM_FAMILY C3D = 24, CPUS_ALL_REGIONS = 32) rule out
# larger C3D SKUs without a quota increase request; per the
# 2026-09-05 conversation the user picked c3d-highmem-16 to ship
# the build today and accept the longer runtime.
#
# 24h cap (the Spot maximum) gives generous slack for repo-sync
# retries if Spot reclaims the instance (a 30-second preemption
# notice is honoured by the watchdog; ccache survives, repo sync
# resumes from where it left off).
$InstanceType = 'c3d-highmem-16'
$SnapshotName = 'qalos-build-warm'
$DiskSizeGb = 500
$MaxRuntimeMinutes = 1440
$NetworkTier = 'STANDARD'

# ---------------------------------------------------------------------------
# Build the env file (same shape as gcp-build.ps1 / do-build.sh expects)
# ---------------------------------------------------------------------------
$envFile = Join-Path $env:TEMP "qalos-env-$(Get-Random).sh"
$qalosDir = 'D:\qalos'
$buildDir = '/root/aosp'
$logDir = "$buildDir/.qalos-logs"
$repoSyncJobs = 8
$repoSyncRetries = 3
$artifactDownloadDir = 'D:\qalos\.worktrees\qa-lab-os-v0\.pi\out\gcp-build'

@"
AOSP_BUILD_TARGET='qalos_emulator'
QALOS_DIR='$qalosDir'
BUILD_DIR='$buildDir'
LOG_DIR='$logDir'
ARTIFACT_DOWNLOAD_DIR='$artifactDownloadDir'
REPO_SYNC_JOBS='$repoSyncJobs'
REPO_SYNC_RETRIES='$repoSyncRetries'
"@ | Out-File -FilePath $envFile -Encoding ascii -NoNewline

# ---------------------------------------------------------------------------
# Create the instance
# ---------------------------------------------------------------------------
$instanceName = "qalos-build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host "[launch] creating $InstanceType Spot instance $instanceName from $SnapshotName..." -ForegroundColor Cyan

$createOutFile = Join-Path $env:TEMP "gcloud_create_$(Get-Random).txt"
$createBat = Join-Path $env:TEMP "gcloud_create_$(Get-Random).bat"
$createContent = "@echo off`r`n`"$gcloudPython`" `"$gcloudScript`" compute instances create $instanceName --zone=$Zone --machine-type=$InstanceType --provisioning-model=SPOT --max-run-duration=${MaxRuntimeMinutes}m --source-snapshot=$SnapshotName --boot-disk-size=${DiskSizeGb}GB --boot-disk-type=pd-ssd --no-service-account --no-scopes --network-tier=$NetworkTier --format=json > `"$createOutFile`" 2>&1"
[System.IO.File]::WriteAllText($createBat, $createContent, [System.Text.UTF8Encoding]::new($false))
$createProc = Start-Process -FilePath $createBat -NoNewWindow -Wait -PassThru
$createRaw = if (Test-Path $createOutFile) { (Get-Content $createOutFile -Raw) } else { '' }
mavis-trash $createOutFile, $createBat 2>&1 | Out-Null
if ($createProc.ExitCode -ne 0) {
    Write-Host "[launch] FAILED to create instance (exit $($createProc.ExitCode)):" -ForegroundColor Red
    Write-Host $createRaw
    exit 1
}
Write-Host "[launch] instance created: $instanceName" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Wait for RUNNING status
# ---------------------------------------------------------------------------
Write-Host "[launch] waiting for RUNNING status..."
$statusOutFile = Join-Path $env:TEMP "gcloud_status_$(Get-Random).txt"
$statusBat = Join-Path $env:TEMP "gcloud_status_$(Get-Random).bat"
$statusContent = "@echo off`r`n`"$gcloudPython`" `"$gcloudScript`" compute instances describe $instanceName --zone=$Zone --format=value(status,networkInterfaces[0].accessConfigs[0].natIP) > `"$statusOutFile`" 2>&1"
[System.IO.File]::WriteAllText($statusBat, $statusContent, [System.Text.UTF8Encoding]::new($false))

$ready = $false
$ip = ''
for ($i = 0; $i -lt 60; $i++) {
    $null = Start-Process -FilePath $statusBat -NoNewWindow -Wait -PassThru
    Start-Sleep -Seconds 5
    $line = if (Test-Path $statusOutFile) { (Get-Content $statusOutFile -Raw).Trim() } else { '' }
    if ($line -match '^RUNNING') {
        $parts = $line -split "`t"
        if ($parts.Count -ge 2) { $ip = $parts[1].Trim() }
        $ready = $true
        break
    }
}
mavis-trash $statusOutFile, $statusBat 2>&1 | Out-Null

if (-not $ready) {
    Write-Host "[launch] instance did not reach RUNNING in 5 min" -ForegroundColor Red
    exit 1
}
Write-Host "[launch] RUNNING, external IP: $ip" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Wait for SSH to be ready
# ---------------------------------------------------------------------------
Write-Host "[launch] waiting for SSH..."
for ($i = 0; $i -lt 60; $i++) {
    $sshTest = & $sshExe -i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL -o LogLevel=ERROR -o ConnectTimeout=5 "bramburn@${ip}" 'echo OK' 2>&1
    if ($LASTEXITCODE -eq 0 -and $sshTest -match 'OK') { break }
    Start-Sleep -Seconds 3
}
Write-Host "[launch] SSH ready" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Upload do-build.sh + the env file
# ---------------------------------------------------------------------------
Write-Host "[launch] uploading do-build.sh and env file..."
$doBuildSh = 'D:\qalos\tools\do-build.sh'
& $scpExe -i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $doBuildSh "bramburn@${ip}:/tmp/do-build.sh"
if ($LASTEXITCODE -ne 0) { Write-Host "[launch] scp do-build.sh FAILED" -ForegroundColor Red; exit 1 }
& $scpExe -i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL $envFile "bramburn@${ip}:/tmp/qalos-env.sh"
if ($LASTEXITCODE -ne 0) { Write-Host "[launch] scp env FAILED" -ForegroundColor Red; exit 1 }
& $sshExe -i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL "bramburn@${ip}" 'sudo cp /tmp/do-build.sh /root/aosp/do-build.sh 2>/dev/null; sudo cp /tmp/qalos-env.sh /root/aosp/qalos-env.sh 2>/dev/null; sudo chmod +x /tmp/do-build.sh; echo uploaded'
Write-Host "[launch] files uploaded" -ForegroundColor Green

# ---------------------------------------------------------------------------
# Launch build via systemd-run (DETACHED) - this is the key fix
# The build will keep running even if the SSH connection drops
# ---------------------------------------------------------------------------
Write-Host "[launch] launching build via systemd-run (detached)..." -ForegroundColor Cyan
# systemd-run creates a clean transient service unit. The /tmp/qalos-env.sh
# file we generated earlier holds the build target / log dir overrides;
# source it inside the unit so do-build.sh sees them. We use systemd's
# --setenv-file form (not bash -c) for the cleaner propagation semantics.
$launchCmd = "sudo systemd-run --unit=qalos-build --setenv-file=/tmp/qalos-env.sh /tmp/do-build.sh"
& $sshExe -i $sshKey -o StrictHostKeyChecking=no -o UserKnownHostsFile=NUL "bramburn@${ip}" $launchCmd
if ($LASTEXITCODE -ne 0) { Write-Host "[launch] systemd-run FAILED" -ForegroundColor Red; exit 1 }
Write-Host "[launch] build launched as qalos-build.service" -ForegroundColor Green
Write-Host ""
Write-Host "[launch] DONE"
Write-Host "[launch] instance: $instanceName"
Write-Host "[launch] ip: $ip"
Write-Host "[launch] next: set up LLM monitor cron with the cron-create helper script"
