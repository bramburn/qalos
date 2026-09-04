# qalos -- on-demand AOSP build on GCP.
#
# Mirrors tools\doctl-build.ps1 and tools\aliyun-build.ps1 for the GCP path.
# Launches a Spot instance from the `qalos-build-warm` snapshot, runs the same
# tools\do-build.sh as the other two paths, then destroys the instance.
#
# Four safety nets ensure the instance is never left running:
#   1. try/finally in this script (graceful exit, Ctrl+C, PowerShell errors).
#   2. On-host watchdog in do-build.sh that force-shuts down after MAX_RUNTIME_MINUTES.
#   3. Background PowerShell job that force-deletes the instance if THIS process dies.
#   4. Final describe check in finally{} to confirm the instance is gone
#      after the wait window -- catches the case where Stop+Delete returned OK
#      but the instance was still billing.
#
# SSH is done via Windows OpenSSH (C:\Windows\System32\OpenSSH\ssh.exe) -- NOT
# via `gcloud compute ssh`. See gcp-smoke-test.ps1 header for the why.
#
# Single source of truth: the on-host build steps are in tools\do-build.sh.
# Only the orchestrator differs between DO / Aliyun / GCP.
#
# Run from D:\qalos:
#     .\tools\gcp-build.ps1
#
# Common flags:
#     -MachineType c3d-standard-16   upgrade to 64 GB RAM if c3d-highcpu-16 OOMs
#     -DiskSizeGb 500                  override boot disk size (default 500 GB)
#     -KeepOnFailure                   leave instance alive 30 min on failure for debugging
#     -MaxRuntimeMinutes 360           hard cap (on-host watchdog also enforces this)

[CmdletBinding()]
param(
    [string]$Zone               = 'us-central1-a',
    [string]$InstanceType       = 'c3d-highcpu-16',
    [int]   $DiskSizeGb         = 500,
    [string]$SnapshotName       = 'qalos-build-warm',
    [string]$QalosRepo         = 'https://github.com/bramburn/qalos.git',
    [string]$AospTag           = 'android-15.0.0_r1',
    [string]$BuildTarget       = 'qalos_emulator',
    [string]$BuildVariant       = 'userdebug',
    [int]   $MaxRuntimeMinutes = 240,
    [switch]$KeepOnFailure     = $false,
    [string]$ArtifactDownloadDir,
    [string]$NetworkTier        = 'STANDARD',
    [switch]$SerialPortOutput   = $true,
    [int]   $RepoSyncJobs      = 8,
    [int]   $RepoSyncRetries   = 3
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# State file (written by gcp-setup-base.ps1)
# ---------------------------------------------------------------------------
$stateFile = Join-Path $PSScriptRoot '..\.pi\gcp-state.json'
if (-not (Test-Path $stateFile)) {
    Write-Host "State file not found: $stateFile" -ForegroundColor Red
    Write-Host "Run .\tools\gcp-setup-base.ps1 first to create the warm snapshot."
    throw "Missing GCP state. Run gcp-setup-base.ps1 first."
}
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
$project = $state.project
Write-Host "[build] project    : $project" -ForegroundColor Cyan
Write-Host "[build] snapshot   : $($state.snapshotName)"
Write-Host "[build] zone       : $Zone"
Write-Host "[build] type       : $InstanceType"
Write-Host "[build] disk       : ${DiskSizeGb}GB"
Write-Host "[build] max-time   : $MaxRuntimeMinutes min"

# ---------------------------------------------------------------------------
# gcloud invocation helper (Python via batch file + Start-Process)
# ---------------------------------------------------------------------------
$gcloudPython = 'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\platform\bundledpython\python.exe'
$gcloudScript = 'C:\Program Files (x86)\Google\Cloud SDK\google-cloud-sdk\lib\gcloud.py'
if (-not (Test-Path $gcloudPython)) { throw "Python not found at $gcloudPython -- reinstall Cloud SDK" }
if (-not (Test-Path $gcloudScript)) { throw "gcloud.py not found at $gcloudScript -- reinstall Cloud SDK" }

function Invoke-Gcloud {
    param([string[]] $GcloudArgs)
    if (-not $GcloudArgs -or $GcloudArgs.Count -eq 0) { throw 'Invoke-Gcloud: GcloudArgs cannot be null or empty' }
    $stdoutFile = "$env:TEMP\qalos-gcp-out-$(Get-Random).tmp"
    $batchFile  = "$env:TEMP\qalos-gcp-$(Get-Random).bat"
    $quotedArgs = $GcloudArgs | ForEach-Object { '"' + $_ + '"' }
    $argLine = $quotedArgs -join ' '
    $batchContent = "@echo off`n`"$gcloudPython`" `"$gcloudScript`" $argLine > `"$stdoutFile`""
    [System.IO.File]::WriteAllText($batchFile, $batchContent, [System.Text.UTF8Encoding]::new($false))
    $proc = Start-Process -FilePath $batchFile -NoNewWindow -Wait -PassThru
    $stdout = if (Test-Path $stdoutFile) { Get-Content $stdoutFile -Raw } else { '' }
    try { Remove-Item $batchFile -ErrorAction SilentlyContinue } catch {}
    try { Remove-Item $stdoutFile -ErrorAction SilentlyContinue } catch {}
    return @{ code = $proc.ExitCode; out = $stdout }
}

# ---------------------------------------------------------------------------
# SSH / SCP helpers using Windows OpenSSH (NOT gcloud's bundled Plink)
# ---------------------------------------------------------------------------
$sshExe  = 'C:\Windows\System32\OpenSSH\ssh.exe'
$scpExe  = 'C:\Windows\System32\OpenSSH\scp.exe'
$sshKey  = Join-Path $env:USERPROFILE '.ssh\google_compute_engine'
$sshUser = $env:USERNAME
if (-not (Test-Path $sshExe)) { throw "OpenSSH not found at $sshExe" }
if (-not (Test-Path $sshKey)) { throw "GCP SSH key not found at $sshKey" }

function Invoke-Ssh {
    param(
        [Parameter(Mandatory)] [string]$Ip,
        [Parameter(Mandatory)] [string]$Command
    )
    $outFile = "$env:TEMP\qalos-ssh-$(Get-Random).out"
    $errFile = "$env:TEMP\qalos-ssh-$(Get-Random).err"
    $args = @(
        '-i', $sshKey,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        '-o', 'ConnectTimeout=15',
        "$sshUser@${Ip}",
        $Command
    )
    $proc = Start-Process -FilePath $sshExe -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    return @{ code = $proc.ExitCode; out = $out; err = $err }
}

function Invoke-ScpUpload {
    param(
        [Parameter(Mandatory)] [string]$LocalPath,
        [Parameter(Mandatory)] [string]$Ip,
        [Parameter(Mandatory)] [string]$RemotePath
    )
    $outFile = "$env:TEMP\qalos-scp-$(Get-Random).out"
    $errFile = "$env:TEMP\qalos-scp-$(Get-Random).err"
    $args = @(
        '-i', $sshKey,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        $LocalPath,
        "${sshUser}@${Ip}:${RemotePath}"
    )
    $proc = Start-Process -FilePath $scpExe -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    return @{ code = $proc.ExitCode; out = $out; err = $err }
}

function Invoke-ScpDownload {
    param(
        [Parameter(Mandatory)] [string]$Ip,
        [Parameter(Mandatory)] [string]$RemotePath,
        [Parameter(Mandatory)] [string]$LocalPath
    )
    $outFile = "$env:TEMP\qalos-scp-$(Get-Random).out"
    $errFile = "$env:TEMP\qalos-scp-$(Get-Random).err"
    $args = @(
        '-i', $sshKey,
        '-o', 'StrictHostKeyChecking=no',
        '-o', 'UserKnownHostsFile=NUL',
        '-o', 'LogLevel=ERROR',
        "${sshUser}@${Ip}:${RemotePath}",
        $LocalPath
    )
    $proc = Start-Process -FilePath $scpExe -ArgumentList $args -NoNewWindow -Wait -PassThru -RedirectStandardOutput $outFile -RedirectStandardError $errFile
    $out = if (Test-Path $outFile) { Get-Content $outFile -Raw } else { '' }
    $err = if (Test-Path $errFile) { Get-Content $errFile -Raw } else { '' }
    return @{ code = $proc.ExitCode; out = $out; err = $err }
}

# Pre-flight auth
$authResult = Invoke-Gcloud -GcloudArgs @('auth', 'list', '--format=json')
if ($authResult.code -ne 0) { throw "gcloud auth list failed (exit $($authResult.code))" }
$active = $authResult.out | ConvertFrom-Json | Where-Object { $_.status -eq 'ACTIVE' } | Select-Object -First 1
if (-not $active) { throw 'No active GCP account. Run: gcloud auth login' }

Write-Host "[build] ssh        : $sshExe" -ForegroundColor DarkGray
Write-Host "[build] ssh-user   : $sshUser" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Artifact download directory
# ---------------------------------------------------------------------------
if (-not $ArtifactDownloadDir) {
    $ArtifactDownloadDir = Join-Path $PSScriptRoot "..\.pi\out\gcp-build\$(Get-Date -Format 'yyyyMMdd-HHmmss')"
}
if (-not (Test-Path $ArtifactDownloadDir)) {
    New-Item -ItemType Directory -Path $ArtifactDownloadDir -Force | Out-Null
}
Write-Host "[build] artifacts  : $ArtifactDownloadDir" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Write the build env file -- scp'd to the instance and sourced in the shell
# ---------------------------------------------------------------------------
$envFile = Join-Path $env:TEMP "qalos-gcp-env-$(Get-Date -Format 'yyyyMMddHHmmss').sh"
@"
# qalos build env -- generated by tools\gcp-build.ps1 at $(Get-Date -Format o)
QALOS_REPO_URL='$QalosRepo'
AOSP_TAG='$AospTag'
BUILD_TARGET='$BuildTarget'
BUILD_VARIANT='$BuildVariant'
MAX_RUNTIME_MINUTES='$MaxRuntimeMinutes'
# GCP path: do-build.sh runs the same build. Artifacts are pulled back via SCP
# rather than uploaded to DO Spaces (which are not configured for GCP).
# Leave SPACES_* blank so do-build.sh skips the upload step gracefully.
SPACES_BUCKET=''
SPACES_REGION=''
SPACES_KEY=''
SPACES_SECRET=''
# Per-run overrides for repo sync. do-build.sh defaults: REPO_SYNC_JOBS=8,
# REPO_SYNC_RETRIES=3. Pass -RepoSyncJobs 4 -RepoSyncRetries 5 (etc.) on the
# gcp-build.ps1 command line to override for this run; useful when a
# previous run hit the android.googlesource.com RESOURCE_EXHAUSTED / HTTP 429
# rate limit.
REPO_SYNC_JOBS='$RepoSyncJobs'
REPO_SYNC_RETRIES='$RepoSyncRetries'
"@ | Out-File -FilePath $envFile -Encoding ascii -NoNewline

# ---------------------------------------------------------------------------
# Create the Spot build instance from the warm snapshot
# ---------------------------------------------------------------------------
$instanceName = "qalos-build-$(Get-Date -Format 'yyyyMMdd-HHmmss')"
Write-Host ""
Write-Host "[build] creating Spot instance $instanceName..." -ForegroundColor Cyan

$createResult = Invoke-Gcloud -GcloudArgs @(
    'compute', 'instances', 'create', $instanceName,
    '--zone', $Zone,
    '--machine-type', $InstanceType,
    '--provisioning-model', 'SPOT',
    '--max-run-duration', "${MaxRuntimeMinutes}m",
    '--source-snapshot', $SnapshotName,
    '--boot-disk-size', "$DiskSizeGb",
    '--boot-disk-type', 'pd-ssd',
    '--no-service-account',
    '--no-scopes',
    '--network-tier', $NetworkTier,
    '--format', 'json'
)
if ($createResult.code -ne 0) { throw "Instance creation failed (exit $($createResult.code))`n$($createResult.out)" }

$instanceData = $createResult.out.Trim() | ConvertFrom-Json
$selfLink = $instanceData[0].selfLink
Write-Host "[build] instance created: $instanceName" -ForegroundColor Green
Write-Host "[build] (hint: the LLM driver should now call mavis cron create to monitor this build; the script intentionally does not set up the cron itself)" -ForegroundColor DarkGray

# ---------------------------------------------------------------------------
# Background watchdog -- force-delete instance if this process dies
# ---------------------------------------------------------------------------
$watchdog = Start-Job -Name "qalos-gcp-build-watchdog-$instanceName" -ArgumentList $instanceName, $Zone, $gcloudPython, $gcloudScript -ScriptBlock {
    param($name, $zone, $gcloudPython, $gcloudScript)
    $parentPid = $PID
    while ($true) {
        Start-Sleep -Seconds 10
        $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if (-not $parent) {
            $tmpBat = [System.IO.Path]::GetTempFileName() + ".bat"
            $content = "@`"$gcloudPython`" `"$gcloudScript`" compute instances stop $name --zone=$zone >nul 2>&1"
            [System.IO.File]::WriteAllText($tmpBat, $content, [System.Text.UTF8Encoding]::new($false))
            $null = Start-Process $tmpBat -NoNewWindow -Wait
            Start-Sleep -Seconds 10
            $content2 = "@`"$gcloudPython`" `"$gcloudScript`" compute instances delete $name --zone=$zone --quiet >nul 2>&1"
            [System.IO.File]::WriteAllText($tmpBat, $content2, [System.Text.UTF8Encoding]::new($false))
            $null = Start-Process $tmpBat -NoNewWindow -Wait
            Remove-Item $tmpBat -ErrorAction SilentlyContinue
            exit 0
        }
    }
}

$buildSucceeded = $false

try {
    # Wait for RUNNING
    Write-Host "[build] waiting for RUNNING status..." -ForegroundColor DarkGray
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $st = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'describe', $instanceName, '--zone', $Zone, '--format', 'value(status)')
        $status = $st.out.Trim()
        if ($status -eq 'RUNNING') {
            Write-Host "[build] status: RUNNING" -ForegroundColor Green
            break
        }
        Write-Host "  status=$status" -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
    if ((Get-Date) -ge $deadline) { throw "Instance did not reach RUNNING within 5 minutes" }

    # Get the external IP
    $ipResult = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'describe', $instanceName, '--zone', $Zone, '--format', 'value(networkInterfaces[0].accessConfigs[0].natIP)')
    $extIp = $ipResult.out.Trim()
    if (-not $extIp) { throw 'Instance has no external IP' }
    Write-Host "[build] external IP: $extIp" -ForegroundColor Green

    # Wait for SSH (native Windows OpenSSH)
    Write-Host "[build] waiting for SSH to be ready..." -ForegroundColor DarkGray
    $sshReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        $sshResult = Invoke-Ssh -Ip $extIp -Command 'echo ready'
        if ($sshResult.code -eq 0) {
            $sshReady = $true
            Write-Host "[build] SSH OK" -ForegroundColor Green
            break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $sshReady) {
        throw "SSH not ready within 2.5 minutes. The cleanup logic in finally{} will destroy the instance."
    }

    # Upload build script + env to the instance
    Write-Host "[build] uploading build script and env to the instance..." -ForegroundColor Cyan
    $doBuild = Join-Path $PSScriptRoot 'do-build.sh'
    if (-not (Test-Path $doBuild)) { throw "do-build.sh not found at $doBuild" }

    $scp1 = Invoke-ScpUpload -LocalPath $envFile -Ip $extIp -RemotePath '/tmp/qalos-env.sh'
    if ($scp1.code -ne 0) { throw "SCP env upload failed (exit $($scp1.code)): $($scp1.err)" }

    $scp2 = Invoke-ScpUpload -LocalPath $doBuild -Ip $extIp -RemotePath '/tmp/do-build.sh'
    if ($scp2.code -ne 0) { throw "SCP do-build.sh upload failed (exit $($scp2.code)): $($scp2.err)" }

    Write-Host "[build] files uploaded" -ForegroundColor Green

    # Run the build -- this takes 1-6 hours
    # do-build.sh has its own watchdog (safety net #2) that fires at MAX_RUNTIME_MINUTES
    Write-Host "[build] running tools\do-build.sh on the instance (max ${MaxRuntimeMinutes} min)..." -ForegroundColor Cyan
    Write-Host "[build] watch the progress at: ssh -i $sshKey $sshUser@$extIp 'tail -f \$HOME/aosp/.qalos-logs/build.log'" -ForegroundColor DarkGray

    $sshRunResult = Invoke-Ssh -Ip $extIp -Command "source /tmp/qalos-env.sh && sudo bash /tmp/do-build.sh"
    if ($sshRunResult.code -ne 0) {
        throw "do-build.sh exited with code $($sshRunResult.code)`n$($sshRunResult.out)`n$($sshRunResult.err)"
    }

    $buildSucceeded = $true
    Write-Host ""
    Write-Host "[build] build complete" -ForegroundColor Green

    # Pull artifacts back via SCP
    Write-Host "[build] pulling artifacts to $ArtifactDownloadDir..." -ForegroundColor Cyan

    $remoteArtifactDir = "/root/aosp/out/target/product/$BuildTarget"
    $localImgDir = Join-Path $ArtifactDownloadDir 'images'
    New-Item -ItemType Directory -Path $localImgDir -Force | Out-Null

    foreach ($img in @('system.img', 'boot.img', 'userdata.img', 'vendor.img', 'product.img')) {
        $localPath = Join-Path $localImgDir $img
        $remotePath = "$remoteArtifactDir/$img"
        $checkResult = Invoke-Ssh -Ip $extIp -Command "test -f $remotePath && echo EXISTS || echo MISSING"
        if ($checkResult.out -match 'EXISTS') {
            $scpResult = Invoke-ScpDownload -Ip $extIp -RemotePath $remotePath -LocalPath $localPath
            if (Test-Path $localPath) {
                $size = (Get-Item $localPath).Length / 1GB
                Write-Host "[build]   $img  ($(('{0:N2}' -f $size)) GB)" -ForegroundColor Green
            }
        } else {
            Write-Host "[build]   $img  (not built, skipping)" -ForegroundColor DarkGray
        }
    }

    # Pull the build log
    $localLog = Join-Path $ArtifactDownloadDir 'build.log'
    $logScp = Invoke-ScpDownload -Ip $extIp -RemotePath '/root/aosp/.qalos-logs/build.log' -LocalPath $localLog
    if (Test-Path $localLog) {
        Write-Host "[build]   build.log  ($(('{0:N2}' -f ((Get-Item $localLog).Length / 1MB))) MB)" -ForegroundColor Green
    }

    Write-Host "[build] artifacts saved to: $ArtifactDownloadDir" -ForegroundColor Green

} catch {
    Write-Warning "[build] build failed: $_"
    if ($KeepOnFailure) {
        Write-Host "[build] KeepOnFailure is set -- leaving instance alive for 30 min for debugging." -ForegroundColor Yellow
        Write-Host "  Connect: ssh -i $sshKey $sshUser@$extIp"
        Write-Host "  Logs   : tail -f /root/aosp/.qalos-logs/build.log"
        Start-Sleep -Seconds 1800
    }
} finally {
    # Always stop + delete the instance (safety nets #1 and #4)

    # Capture serial port output BEFORE stopping the instance -- after stop
    # the serial buffer stops accepting new output. Useful for debugging
    # boot failures, kernel panics, watchdog-triggered shutdowns.
    # Default gcloud behaviour returns the last 1 MB of the serial buffer,
    # which is enough for boot logs + kernel panic + shutdown reason.
    if ($SerialPortOutput) {
        $serialOut = "$ArtifactDownloadDir\serial-console.log"
        $null = New-Item -ItemType Directory -Path $ArtifactDownloadDir -Force
        $serialResult = Invoke-Gcloud -GcloudArgs @(
            'compute', 'instances', 'get-serial-port-output', $instanceName,
            '--zone', $Zone,
            '--port', '1'
        )
        if ($serialResult.code -eq 0 -and $serialResult.out) {
            [System.IO.File]::WriteAllText($serialOut, $serialResult.out, [System.Text.UTF8Encoding]::new($false))
            $serialSize = (Get-Item $serialOut).Length
            Write-Host "[build] serial console captured: $serialOut ($serialSize bytes)" -ForegroundColor DarkGray
        } else {
            Write-Warning "[build] serial console capture failed (exit $($serialResult.code)): $($serialResult.out)"
        }
    }

    Write-Host "[build] stopping instance $instanceName..." -ForegroundColor Cyan
    $null = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'stop', $instanceName, '--zone', $Zone)

    # Wait for TERMINATED
    $stopDeadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $stopDeadline) {
        $st = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'describe', $instanceName, '--zone', $Zone, '--format', 'value(status)')
        if ($st.out.Trim() -eq 'TERMINATED') { break }
        Start-Sleep -Seconds 3
    }

    Write-Host "[build] deleting instance $instanceName..." -ForegroundColor Cyan
    $null = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'delete', $instanceName, '--zone', $Zone, '--quiet')

    Stop-Job  $watchdog -ErrorAction SilentlyContinue
    Remove-Job $watchdog -Force -ErrorAction SilentlyContinue

    # Safety net #4: use describe NOT_FOUND to confirm destroy
    Write-Host "[build] final verification -- confirming destroy..." -ForegroundColor DarkGray
    Start-Sleep -Seconds 5
    $checkResult = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'describe', $instanceName, '--zone', $Zone, '--format', 'value(name)')
    if ($checkResult.out -match 'NOT_FOUND' -or $checkResult.out -match 'was not found' -or $checkResult.code -ne 0) {
        Write-Host "[build] instance confirmed deleted" -ForegroundColor Green
    } else {
        Write-Warning "[build] WARNING: instance still exists after delete. Retrying Stop+Delete..." -ForegroundColor Yellow
        $null = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'stop', $instanceName, '--zone', $Zone)
        Start-Sleep -Seconds 10
        $null = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'delete', $instanceName, '--zone', $Zone, '--quiet')
        Start-Sleep -Seconds 3
        $check2 = Invoke-Gcloud -GcloudArgs @('compute', 'instances', 'describe', $instanceName, '--zone', $Zone, '--format', 'value(name)')
        if (-not ($check2.out -match 'NOT_FOUND' -or $check2.out -match 'was not found')) {
            Write-Warning "[build] CRITICAL: instance $instanceName STILL billing. Manually delete at:" -ForegroundColor Red
            Write-Warning "  gcloud compute instances delete $instanceName --zone=$Zone"
        } else {
            Write-Host "[build] instance confirmed deleted after retry" -ForegroundColor Green
        }
    }

    # Clean up temp env file
    Remove-Item $envFile -ErrorAction SilentlyContinue
}

Write-Host ""
if ($buildSucceeded) {
    Write-Host "[build] PASS" -ForegroundColor Green
    exit 0
} else {
    Write-Host "[build] FAIL" -ForegroundColor Red
    exit 1
}
