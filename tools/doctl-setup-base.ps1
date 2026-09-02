# qalos — one-time base-droplet setup.
#
# Spins up a fresh c-8 droplet from the stock Ubuntu 22.04 image, runs
# tools/setup-droplet.sh to install every AOSP build dependency, then
# snapshots the result as `qalos-build-warm`. Subsequent on-demand builds
# create droplets from this snapshot, which is the whole point of the
# build-on-demand pattern (no apt installs, no dependency hunting on every
# build).
#
# Run from D:\qalos once DO_API_TOKEN is set:
#     .\tools\doctl-setup-base.ps1
#
# Cost: ~$0.18 for ~10 min of droplet time + a $0.10/GB/month snapshot standing
# charge (the qalos-build-warm snapshot is ~3-4 GB, so about $0.40/month).

[CmdletBinding()]
param(
    [string]$DropletName    = 'qalos-base',
    [string]$DropletSize    = 'c-8',
    [string]$Region         = 'lon1',
    [string]$ImageBase      = 'ubuntu-22-04-x64',
    [string]$SnapshotName   = 'qalos-build-warm',
    [string]$QalosBranch    = 'main'
)

$ErrorActionPreference = 'Stop'

if (-not (Get-Command doctl -ErrorAction SilentlyContinue)) {
    throw "doctl not found. Run tools\doctl-install.ps1 first."
}

# Resolve the SSH key fingerprint — every DO droplet needs at least one.
$keyId = doctl compute ssh-key list --format ID --no-header | Select-Object -First 1
if (-not $keyId) {
    throw "No SSH key registered with DigitalOcean. Add one at https://cloud.digitalocean.com/account/security, or run `doctl compute ssh-key import`."
}

Write-Host "[qalos] creating base droplet $DropletName ($DropletSize in $Region)..."
$created = doctl compute droplet create $DropletName `
    --image    $ImageBase `
    --size     $DropletSize `
    --region   $Region `
    --ssh-keys $keyId `
    --tag-names 'qalos,base' `
    --wait `
    --format 'ID,PublicIPv4,Status' --no-header

$dropletId = ($created -split '\s+')[0].Trim()
$dropletIp = ($created -split '\s+')[1].Trim()
Write-Host "[qalos] droplet $dropletId at $dropletIp"

# Wait for SSH to be reachable.
$ready = $false
for ($i = 0; $i -lt 30; $i++) {
    if (ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$dropletIp" "echo ready" 2>$null) {
        $ready = $true
        break
    }
    Start-Sleep -Seconds 5
}
if (-not $ready) {
    doctl compute droplet delete $dropletId --force | Out-Null
    throw "Droplet did not become SSH-ready within 2.5 minutes. Aborted."
}

try {
    Write-Host "[qalos] running setup-droplet.sh on the base droplet (5-10 min)..."
    $setupScript = Join-Path $PSScriptRoot 'setup-droplet.sh'
    scp $setupScript "root@${dropletIp}:/tmp/setup-droplet.sh"
    ssh "root@$dropletIp" "bash /tmp/setup-droplet.sh"

    if ($LASTEXITCODE -ne 0) {
        throw "setup-droplet.sh failed with exit $LASTEXITCODE"
    }
}
finally {
    # Power down the droplet before snapshotting — DO prefers this.
    Write-Host "[qalos] powering off the base droplet for a clean snapshot..."
    ssh "root@$dropletIp" "shutdown -h now" 2>$null
    # Wait for the droplet to actually stop.
    for ($i = 0; $i -lt 20; $i++) {
        $status = doctl compute droplet get $dropletId --format Status --no-header
        if ($status -eq 'off') { break }
        Start-Sleep -Seconds 5
    }
}

# Snapshot it.
Write-Host "[qalos] creating snapshot '$SnapshotName' (this can take a few minutes)..."
$snap = doctl compute snapshot create $SnapshotName `
    --droplet-id $dropletId `
    --tag-names 'qalos,build-base' `
    --wait `
    --format 'ID,Name,Status' --no-header
Write-Host "[qalos] snapshot created: $snap"

# Tidy up the base droplet — the snapshot is the artefact we keep.
Write-Host "[qalos] deleting the base droplet $dropletId..."
doctl compute droplet delete $dropletId --force | Out-Null

Write-Host ""
Write-Host "[qalos] base setup complete."
Write-Host "  snapshot:   $SnapshotName  (id:  $((($snap -split '\s+')[0]).Trim()))"
Write-Host "  region:     $Region"
Write-Host "  size used:  $DropletSize"
Write-Host "  qalos ref:  branch $QalosBranch"
Write-Host ""
Write-Host "Next: trigger a build with .\tools\doctl-build.ps1"
