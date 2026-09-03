# qalos - one-time Aliyun base ECS setup.
#
# Mirrors tools\doctl-setup-base.ps1 for the DigitalOcean path. The DO version
# creates a "warm" base droplet, runs tools\setup-droplet.sh (AOSP build deps),
# then snapshots the result as `qalos-build-warm` so subsequent on-demand builds
# launch from that snapshot and skip the apt install step.
#
# On Aliyun, the equivalent artefact is a *custom image* (not a snapshot - Aliyun
# does not expose snapshot-from-instance the same way DO does). This script:
#
#   1. Launches a small base ECS in cn-hangzhou / cn-hangzhou-h, using the same
#      VPC/vSwitch/SG/KeyPair the smoke test bootstrapped.
#   2. Waits for it to be SSH-reachable.
#   3. SCPs tools\setup-droplet.sh to the instance, runs it.
#   4. Powers the instance off (clean state for image capture).
#   5. Creates a custom image called `qalos-build-warm` from the stopped ECS.
#   6. Deletes the base ECS - the image is the artefact we keep.
#
# Cost: ~0.18 CNY for ~10 min of e-c1m1.large runtime + ~0.12 CNY/GB/month
# for the custom image (probably 8-12 GB, so ~1 CNY/month standing charge).
#
# Run from D:\qalos once aliyun is configured:
#     .\tools\aliyun-setup-base.ps1
#
# Or override defaults:
#     .\tools\aliyun-setup-base.ps1 -Region cn-shanghai -InstanceType ecs.u1-c1m8.2xlarge

[CmdletBinding()]
param(
    [string]$Region          = 'cn-hangzhou',
    [string]$Zone            = 'cn-hangzhou-h',
    [string]$BaseName        = 'qalos-base',
    [string]$ImageName       = 'qalos-build-warm',
    [string]$ImageBase       = 'ubuntu_22_04_x64_20G_alibase_20260810.vhd',
    [string]$InstanceType    = 'ecs.e-c1m1.large',   # 2 vCPU / 2 GB; swap in u1-c1m8.2xlarge for the real warm image
    [string]$Prefix          = 'qalos-smoke',         # reuse the smoke-test VPC/SG/keypair
    [string]$QalosBranch     = 'main'
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

$aliyun = Join-Path $env:LOCALAPPDATA 'AliyunCLI\aliyun.exe'
if (-not (Test-Path $aliyun)) { throw "aliyun CLI not found. Run tools\aliyun-install.ps1 first." }
if (-not (& $aliyun configure list 2>&1 | Out-String | Select-String -Pattern 'default\s*\*')) {
    throw "no default aliyun profile. Run 'aliyun configure' first."
}

# Load the infra state that aliyun-smoke-test.ps1 saved
$stateFile = Join-Path $PSScriptRoot '..\.pi\aliyun-state.json'
if (-not (Test-Path $stateFile)) { throw "state file not found: $stateFile. Run tools\aliyun-smoke-test.ps1 first (it bootstraps the VPC/vSwitch/SG/KeyPair and saves the state)." }
$state = Get-Content $stateFile -Raw | ConvertFrom-Json
if ($state.region -ne $Region) {
    Write-Warning "state file region $($state.region) != -Region $Region. Using state's region for consistency."
    $Region = $state.region
    $Zone   = $state.zone
}
$vpcId   = $state.vpcId
$vswId   = $state.vswId
$sgId    = $state.sgId
$kpName  = $state.keyPairName
Write-Host "[setup-base] using $vpcId / $vswId / $sgId / $kpName from $stateFile"

# Re-resolve the most recent Ubuntu 22.04 image in this region.
$imgResp = & $aliyun ecs DescribeImages --RegionId $Region --ImageOwnerAlias system --OSType linux --Architecture x86_64 --PageSize 100 2>&1 | Out-String
$idx = $imgResp.IndexOf('{')
$imgs = ($imgResp.Substring($idx) | ConvertFrom-Json).Images.Image
$img  = $imgs | Where-Object { $_.OSName -match 'ubuntu_22_04' } | Sort-Object { [datetime]$_.CreationTime } -Descending | Select-Object -First 1
if (-not $img) { throw "no ubuntu_22_04 image in $Region" }
$imageId = $img.ImageId
Write-Host "[setup-base] image: $imageId ($($img.OSName))"

# Launch base ECS
$now = (Get-Date).ToString('HHmmss')
$baseName = "$BaseName-$now"
Write-Host "[setup-base] launching $baseName ($InstanceType)..." -ForegroundColor Cyan
$ri = & $aliyun ecs RunInstances `
    --RegionId $Region `
    --ImageId $imageId `
    --InstanceType $InstanceType `
    --SecurityGroupId $sgId `
    --VSwitchId $vswId `
    --InstanceName $baseName `
    --InstanceChargeType PostPaid `
    --InternetMaxBandwidthOut 5 `
    --InternetChargeType PayByTraffic `
    --SystemDisk.Category cloud_essd `
    --SystemDisk.Size 100 `
    --KeyPairName $kpName `
    --Amount 1 `
    --HostName "qalos-base-$now" 2>&1 | Out-String
$idx2 = $ri.IndexOf('{')
if ($idx2 -lt 0) { throw "RunInstances returned no JSON. Output: $ri" }
$baseId = ($ri.Substring($idx2) | ConvertFrom-Json).InstanceIdSets.InstanceIdSet[0]
Write-Host "[setup-base] base ECS: $baseId" -ForegroundColor Green

# Watchdog: if this script is killed, force-delete the base ECS.
$watchdog = Start-Job -ScriptBlock {
    param($aliyunPath, $region, $instanceId, $parentPid)
    while ($true) {
        Start-Sleep -Seconds 5
        $parent = Get-Process -Id $parentPid -ErrorAction SilentlyContinue
        if (-not $parent) {
            & $aliyunPath ecs StopInstance  --RegionId $region --InstanceId $instanceId 2>$null | Out-Null
            Start-Sleep -Seconds 5
            & $aliyunPath ecs DeleteInstance --RegionId $region --InstanceId $instanceId --Force true 2>$null | Out-Null
            exit 0
        }
    }
} -ArgumentList @($aliyun, $Region, $baseId, $PID)

try {
    # Wait for Running + get public IP
    $publicIp = $null
    $deadline = (Get-Date).AddMinutes(5)
    while ((Get-Date) -lt $deadline) {
        $d = & $aliyun ecs DescribeInstances --RegionId $Region --InstanceIds "['$baseId']" 2>&1 | Out-String
        $didx = $d.IndexOf('{')
        $obj  = if ($didx -ge 0) { $d.Substring($didx) | ConvertFrom-Json } else { $null }
        $inst = $obj.Instances.Instance
        if ($inst) {
            $status = $inst[0].Status
            $publicIp = $inst[0].PublicIpAddress.IpAddress
            if ($publicIp -is [array]) { $publicIp = $publicIp[0] }
            if ($status -eq 'Running' -and $publicIp) { break }
            Write-Host "  status=$status ip=$publicIp" -ForegroundColor DarkGray
        }
        Start-Sleep -Seconds 5
    }
    if (-not $publicIp) { throw "base ECS did not become SSH-ready within 5 minutes" }
    Write-Host "[setup-base] base ECS running at $publicIp" -ForegroundColor Green

    # Wait for SSH
    $sshReady = $false
    for ($i = 0; $i -lt 30; $i++) {
        if (ssh -o ConnectTimeout=5 -o StrictHostKeyChecking=no "root@$publicIp" "echo ready" 2>$null) {
            $sshReady = $true; break
        }
        Start-Sleep -Seconds 5
    }
    if (-not $sshReady) { throw "SSH not ready on $publicIp after 2.5 min. Aborting (base ECS will be force-deleted)." }

    # Run setup-droplet.sh (the same AOSP setup script the DO path uses)
    Write-Host "[setup-base] running tools\setup-droplet.sh on the base ECS (5-10 min)..." -ForegroundColor Cyan
    $setupScript = Join-Path $PSScriptRoot 'setup-droplet.sh'
    scp $setupScript "root@${publicIp}:/tmp/setup-droplet.sh"
    ssh "root@$publicIp" "bash /tmp/setup-droplet.sh"
    if ($LASTEXITCODE -ne 0) { throw "setup-droplet.sh failed with exit $LASTEXITCODE" }
    Write-Host "[setup-base] setup-droplet.sh complete" -ForegroundColor Green

    # Power off (clean state for image capture)
    Write-Host "[setup-base] powering off base ECS for clean image capture..." -ForegroundColor Cyan
    ssh "root@$publicIp" "shutdown -h now" 2>$null
    $stopDeadline = (Get-Date).AddMinutes(2)
    while ((Get-Date) -lt $stopDeadline) {
        $d = & $aliyun ecs DescribeInstances --RegionId $Region --InstanceIds "['$baseId']" 2>&1 | Out-String
        $didx = $d.IndexOf('{')
        $obj  = if ($didx -ge 0) { $d.Substring($didx) | ConvertFrom-Json } else { $null }
        $inst = $obj.Instances.Instance
        if ($inst -and $inst[0].Status -eq 'Stopped') { break }
        Start-Sleep -Seconds 5
    }

    # Create the custom image (this is the warm artefact we keep)
    Write-Host "[setup-base] creating custom image '$ImageName'..." -ForegroundColor Cyan
    $ci = & $aliyun ecs CreateImage `
        --RegionId $Region `
        --InstanceId $baseId `
        --ImageName $ImageName `
        --Description "qalos warm AOSP build image (AOSP $QalosBranch, base $InstanceType)" 2>&1 | Out-String
    $ciidx = $ci.IndexOf('{')
    if ($ciidx -lt 0) { throw "CreateImage returned no JSON. Output: $ci" }
    $imageId = ($ci.Substring($ciidx) | ConvertFrom-Json).ImageId
    Write-Host "[setup-base] custom image: $imageId" -ForegroundColor Green
}
finally {
    # Always clean up the base ECS - the image is the artefact
    Write-Host "[setup-base] deleting base ECS $baseId..." -ForegroundColor Cyan
    & $aliyun ecs DeleteInstance --RegionId $Region --InstanceId $baseId --Force true 2>&1 | Out-Null
    if ($watchdog) { Stop-Job -Job $watchdog -ErrorAction SilentlyContinue; Remove-Job -Job $watchdog -Force -ErrorAction SilentlyContinue }
}

# Update the state file with the new image id
$state | Add-Member -NotePropertyName warmImageId -NotePropertyValue $imageId -Force
$state | Add-Member -NotePropertyName warmImageName -NotePropertyValue $ImageName -Force
$state.updatedAt = (Get-Date).ToString('o')
$state | ConvertTo-Json -Depth 4 | Set-Content -Path $stateFile -Encoding UTF8

Write-Host ""
Write-Host "[setup-base] DONE." -ForegroundColor Green
Write-Host "  base ECS     : $baseId  (deleted)"
Write-Host "  warm image   : $imageId ($ImageName)"
Write-Host "  region/zone  : $Region / $Zone"
Write-Host "  state file   : $stateFile"
Write-Host ""
Write-Host "Next: run tools\aliyun-build.ps1 to launch a build from this warm image."
