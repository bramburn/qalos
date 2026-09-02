# qalos — on-demand AOSP build.
#
# Spins up a fresh c-8 droplet from the `qalos-build-warm` snapshot, runs
# tools/do-build.sh, waits for it to finish, and destroys the droplet. The
# droplet is destroyed in three independent ways to make sure it can never
# be left running and burning money:
#
#   1. try/finally in this script (graceful exit, Ctrl+C, PowerShell errors).
#   2. on-droplet watchdog in do-build.sh that force-kills + shuts down
#      after MAX_RUNTIME_MINUTES.
#   3. background PowerShell job in this script that force-destroys the
#      droplet if THIS process dies (catches the case where PowerShell is
#      killed harder than Ctrl+C can catch).
#
# Required env:
#     DO_API_TOKEN             DigitalOcean API token (read+write)
#     QALOS_SPACES_BUCKET      DO Spaces bucket name, e.g. "qalos-builds"
#     QALOS_SPACES_KEY         DO Spaces access key
#     QALOS_SPACES_SECRET      DO Spaces secret key
#
# Optional env (with defaults):
#     QALOS_SPACES_REGION      default: lon1
#     QALOS_REPO_URL           default: https://github.com/bramburn/qalos.git
#
# Common flags:
#     -Size c-16               upgrade to 16 vCPU / 32 GB if c-8 hits OOM
#     -KeepOnFailure           leave the droplet alive for 30 min on failure
#                              so you can SSH in and inspect the build log
#     -MaxRuntimeMinutes 360   hard cap on the build (watchdog also enforces)

[CmdletBinding()]
param(
    [string]$DropletSize       = 'c-8',
    [string]$Region            = $env:QALOS_SPACES_REGION ? $env:QALOS_SPACES_REGION : 'lon1',
    [string]$SnapshotName      = 'qalos-build-warm',
    [string]$QalosRepo         = $env:QALOS_REPO_URL     ? $env:QALOS_REPO_URL     : 'https://github.com/bramburn/qalos.git',
    [string]$BuildTarget       = 'qalos_emulator',
    [string]$BuildVariant      = 'userdebug',
    [int]$MaxRuntimeMinutes    = 240,
    [switch]$KeepOnFailure     = $false,
    [string]$SpacesBucket      = $env:QALOS_SPACES_BUCKET
)

$ErrorActionPreference = 'Stop'

# ---------------------------------------------------------------------------
# Pre-flight
# ---------------------------------------------------------------------------
if (-not (Get-Command doctl -ErrorAction SilentlyContinue)) {
    throw "doctl not found. Run tools\doctl-install.ps1 first."
}
if (-not $env:DO_API_TOKEN -and -not (doctl auth list 2>$null)) {
    throw "DO_API_TOKEN env var not set. Generate one at https://cloud.digitalocean.com/account/api/tokens/new"
}
if (-not $SpacesBucket) {
    throw "QALOS_SPACES_BUCKET env var not set. Create a Spaces bucket and set the env var."
}
if (-not $env:QALOS_SPACES_KEY -or -not $env:QALOS_SPACES_SECRET) {
    throw "QALOS_SPACES_KEY / QALOS_SPACES_SECRET env vars not set. Generate at https://cloud.digitalocean.com/account/api/spaces."
}

# Resolve the snapshot ID (cached per-session in a local file).
$cacheFile = Join-Path $env:TEMP 'qalos-snapshot-id.txt'
$snapshotId = $null
if (Test-Path $cacheFile) {
    $cached = Get-Content $cacheFile -Raw -ErrorAction SilentlyContinue
    if ($cached -and ($cached -match '^(?<id>\d+)\s+(?<name>.+)$')) {
        $verified = doctl compute snapshot get $Matches.id --format 'ID,Name' --no-header 2>$null
        if ($verified -and $verified.Trim().StartsWith($Matches.id) -and $verified -match [regex]::Escape($Matches.name)) {
            $snapshotId = $Matches.id
        }
    }
}
if (-not $snapshotId) {
    Write-Host "[qalos] looking up snapshot '$SnapshotName' in $Region..."
    $rows = doctl compute snapshot list --region $Region --format 'ID,Name' --no-header
    foreach ($row in $rows) {
        $parts = ($row -split '\s+', 2).Trim()
        if ($parts.Count -ge 2 -and $parts[1] -eq $SnapshotName) {
            $snapshotId = $parts[0]
            Set-Content -Path $cacheFile -Value "$snapshotId $SnapshotName" -NoNewline
            break
        }
    }
}
if (-not $snapshotId) {
    throw "Snapshot '$SnapshotName' not found in region $Region. Run tools\doctl-setup-base.ps1 to create it."
}

$keyId = doctl compute ssh-key list --format ID --no-header | Select-Object -First 1
if (-not $keyId) {
    throw "No SSH key registered with DigitalOcean. Add one in the control panel or via `doctl compute ssh-key import`."
}

# ---------------------------------------------------------------------------
# Create the droplet
# ---------------------------------------------------------------------------
$dropletName = "qalos-build-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Write-Host "[qalos] creating droplet $dropletName ($DropletSize from snapshot $SnapshotName)..."

$created = doctl compute droplet create $dropletName `
    --image    $snapshotId `
    --size     $DropletSize `
    --region   $Region `
    --ssh-keys $keyId `
    --tag-names 'qalos,build' `
    --wait `
    --format 'ID,PublicIPv4,Status' --no-header

$dropletId = ($created -split '\s+')[0].Trim()
$dropletIp = ($created -split '\s+')[1].Trim()
Write-Host "[qalos] droplet $dropletId at $dropletIp"

# ---------------------------------------------------------------------------
# Background watchdog — a separate PowerShell job that destroys the droplet
# if the parent process dies. This catches the case where PowerShell is
# killed harder than a try/finally can handle (e.g. crash, force-kill).
# ---------------------------------------------------------------------------
$watchdog = Start-Job -Name "qalos-watchdog-$dropletId" -ArgumentList $dropletId, $MaxRuntimeMinutes -ScriptBlock {
    param($id, $minutes)
    $endTime = (Get-Date).AddMinutes($minutes + 5)  # 5-min grace beyond the on-droplet watchdog
    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Seconds 30
        $status = doctl compute droplet get $id --format Status --no-header 2>$null
        if ($status -ne 'active') { return }
    }
    # If we got here, the parent died AND the on-droplet watchdog didn't fire.
    # Belt-and-braces final destroy.
    doctl compute droplet delete $id --force 2>$null | Out-Null
}

# ---------------------------------------------------------------------------
# Wait for SSH
# ---------------------------------------------------------------------------
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    if (ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$dropletIp" "echo ready" 2>$null) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) {
    throw "Droplet $dropletId did not become SSH-ready. The cleanup logic in finally will destroy it."
}

# ---------------------------------------------------------------------------
# Run the build. try/finally is the primary safety net; the watchdog job is
# the secondary net for hard parent-process death.
# ---------------------------------------------------------------------------
$buildScript = Join-Path $PSScriptRoot 'do-build.sh'

# Write the build env to a temp file, scp it across, source it on the remote.
# (We do this rather than passing vars inline so values containing single
# quotes — common in Spaces secrets — don't break the remote shell parsing.)
$envFile = [System.IO.Path]::GetTempFileName()
@"
# qalos build env — generated by doctl-build.ps1
SPACES_BUCKET='$SpacesBucket'
SPACES_REGION='$Region'
SPACES_KEY='$env:QALOS_SPACES_KEY'
SPACES_SECRET='$env:QALOS_SPACES_SECRET'
QALOS_REPO_URL='$QalosRepo'
AOSP_TAG='android-15.0.0_r1'
BUILD_TARGET='$BuildTarget'
BUILD_VARIANT='$BuildVariant'
MAX_RUNTIME_MINUTES='$MaxRuntimeMinutes'
"@ | Set-Content -Path $envFile -Encoding utf8NoBOM

$buildOk = $false
try {
    Write-Host "[qalos] uploading build script and env to $dropletIp..."
    scp -o StrictHostKeyChecking=no $envFile      "root@${dropletIp}:/tmp/qalos-env.sh"
    scp -o StrictHostKeyChecking=no $buildScript  "root@${dropletIp}:/tmp/do-build.sh"

    Write-Host "[qalos] running build on $dropletIp (max $MaxRuntimeMinutes min)..."
    ssh -o StrictHostKeyChecking=no "root@$dropletIp" "source /tmp/qalos-env.sh && bash /tmp/do-build.sh"

    if ($LASTEXITCODE -ne 0) {
        throw "build script exited with $LASTEXITCODE"
    }
    $buildOk = $true
    Write-Host "[qalos] build complete. Artifacts uploaded to s3://$SpacesBucket/<timestamp>/"
}
finally {
    Remove-Item $envFile -ErrorAction SilentlyContinue
}
catch {
    Write-Warning "[qalos] build failed: $_"
    if ($KeepOnFailure) {
        Write-Host "[qalos] KeepOnFailure was set — leaving $dropletId alive for 30 minutes for debugging."
        Write-Host "  ssh root@$dropletIp  (then: cat $BUILD_DIR/.qalos-logs/build.log)"
        Start-Sleep -Seconds 1800
    }
}
finally {
    Stop-Job  $watchdog -ErrorAction SilentlyContinue
    Remove-Job $watchdog -ErrorAction SilentlyContinue
    if ($dropletId) {
        Write-Host "[qalos] destroying droplet $dropletId..."
        doctl compute droplet delete $dropletId --force 2>$null | Out-Null
    }
}

if (-not $buildOk) {
    throw "qalos build failed. See the warning above."
}

Write-Host "[qalos] done."
