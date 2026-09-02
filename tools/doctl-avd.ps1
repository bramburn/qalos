# qalos — interactive AVD on a DO droplet.
#
# Spins up a c-8 droplet from the `qalos-build-warm` snapshot, runs
# tools/do-build.sh to (re)build qalos, launches the AVD on the droplet, and
# prints the SSH-tunnel command to connect ADB from this Windows box. The
# droplet stays alive until you press Ctrl+C, after which it is destroyed
# automatically. A background watchdog force-destroys the droplet if the
# parent PowerShell process is killed.
#
# From another PowerShell window, after this script starts:
#     ssh -L 5555:localhost:5555 root@<droplet-ip>
# Then from a third window:
#     adb connect localhost:5555
#     adb shell
#
# (Optional: set up an SSH config entry so the tunnel stays open.)

[CmdletBinding()]
param(
    [string]$DropletSize       = 'c-8',
    [string]$Region            = $env:QALOS_SPACES_REGION ? $env:QALOS_SPACES_REGION : 'lon1',
    [string]$SnapshotName      = 'qalos-build-warm',
    [string]$QalosRepo         = $env:QALOS_REPO_URL     ? $env:QALOS_REPO_URL     : 'https://github.com/bramburn/qalos.git',
    [int]$IdleTimeoutMinutes   = 30,
    [switch]$NoRebuild         = $false
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command doctl -ErrorAction SilentlyContinue)) {
    throw "doctl not found. Run tools\doctl-install.ps1 first."
}

$snapshotId = $null
$snapshotRows = doctl compute snapshot list --region $Region --format 'ID,Name' --no-header
foreach ($row in $snapshotRows) {
    $parts = ($row -split '\s+', 2).Trim()
    if ($parts.Count -ge 2 -and $parts[1] -eq $SnapshotName) {
        $snapshotId = $parts[0]
        break
    }
}
if (-not $snapshotId) {
    throw "Snapshot '$SnapshotName' not found in region $Region. Run tools\doctl-setup-base.ps1 first."
}

$keyId = doctl compute ssh-key list --format ID --no-header | Select-Object -First 1
if (-not $keyId) {
    throw "No SSH key registered with DigitalOcean. Add one in the control panel or via `doctl compute ssh-key import`."
}

$dropletName = "qalos-avd-$([DateTimeOffset]::UtcNow.ToUnixTimeSeconds())"
Write-Host "[qalos] creating AVD droplet $dropletName..."
$created = doctl compute droplet create $dropletName `
    --image    $snapshotId `
    --size     $DropletSize `
    --region   $Region `
    --ssh-keys $keyId `
    --tag-names 'qalos,avd' `
    --wait `
    --format 'ID,PublicIPv4,Status' --no-header

$dropletId = ($created -split '\s+')[0].Trim()
$dropletIp = ($created -split '\s+')[1].Trim()
Write-Host "[qalos] droplet $dropletId at $dropletIp"

# Watchdog — destroys the droplet if this process dies.
$watchdog = Start-Job -Name "qalos-avd-watchdog-$dropletId" -ArgumentList $dropletId, $IdleTimeoutMinutes -ScriptBlock {
    param($id, $minutes)
    $endTime = (Get-Date).AddMinutes($minutes)
    $lastActivity = Get-Date
    while ((Get-Date) -lt $endTime) {
        Start-Sleep -Seconds 30
        $status = doctl compute droplet get $id --format Status --no-header 2>$null
        if ($status -ne 'active') { return }
    }
    doctl compute droplet delete $id --force 2>$null | Out-Null
}

# Wait for SSH.
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    if (ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$dropletIp" "echo ready" 2>$null) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) {
    throw "Droplet did not become SSH-ready. Cleanup in finally will destroy it."
}

try {
    if (-not $NoRebuild) {
        Write-Host "[qalos] running build on the AVD droplet (1-4 hours)..."
        # For AVD we don't need Spaces uploads; build artifacts stay on the droplet.
        ssh "root@$dropletIp" "QALOS_REPO_URL='$QalosRepo' bash /tmp/run-build.sh" 2>$null
    }

    Write-Host ""
    Write-Host "================================================================"
    Write-Host " qalos AVD is up at $dropletIp"
    Write-Host "================================================================"
    Write-Host ""
    Write-Host "To connect ADB from this Windows box:"
    Write-Host ""
    Write-Host "  # in another PowerShell window:"
    Write-Host "  ssh -L 5555:localhost:5555 root@$dropletIp"
    Write-Host ""
    Write-Host "  # in a third window, after the SSH tunnel is up:"
    Write-Host "  adb connect localhost:5555"
    Write-Host "  adb shell"
    Write-Host ""
    Write-Host "Droplet will stay alive until you press Ctrl+C here"
    Write-Host "(or until $IdleTimeoutMinutes minutes of no activity, whichever comes first)."
    Write-Host ""

    # Block on user input. Each press of Enter resets the idle timer (heartbeat).
    $lastTouch = Get-Date
    while ($true) {
        $key = $Host.UI.RawUI.ReadKey('NoEcho,IncludeKeyDown')
        if ($key.KeyAvailable -or $key.VirtualKeyCode -eq 0x03) { break }  # Ctrl+C
        $lastTouch = Get-Date
        # Check droplet is still up.
        $status = doctl compute droplet get $dropletId --format Status --no-header 2>$null
        if ($status -ne 'active') {
            Write-Host "[qalos] droplet is no longer active. Exiting."
            break
        }
        if (((Get-Date) - $lastTouch).TotalMinutes -gt $IdleTimeoutMinutes) {
            Write-Host "[qalos] idle for $IdleTimeoutMinutes minutes — destroying droplet."
            break
        }
    }
}
finally {
    Write-Host "[qalos] destroying AVD droplet $dropletId..."
    Stop-Job  $watchdog -ErrorAction SilentlyContinue
    Remove-Job $watchdog -ErrorAction SilentlyContinue
    if ($dropletId) {
        doctl compute droplet delete $dropletId --force 2>$null | Out-Null
    }
    Write-Host "[qalos] AVD session ended."
}
