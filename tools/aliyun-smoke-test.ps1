# qalos - aliyun smoke test
#
# Purpose: prove the Aliyun CLI + credentials + region work end-to-end by
# spinning up the smallest possible ECS that is actually in stock, confirming
# it transitions to Running, and deleting it. Nothing is left running.
#
# Supporting infrastructure (VPC / vSwitch / Security Group / KeyPair named
# `qalos-smoke-*`) is kept around because it's free and will be reused by
# `aliyun-build.ps1` later. Their IDs are written to
# .pi/aliyun-state.json for the build script to consume.
#
# Mirrors the four-safety-net pattern from `doctl-build.ps1`:
#   1. try/finally  - the instance is force-deleted on any exit path
#   2. Start-Job    - background watchdog force-deletes if this PS dies
#   3. (n/a - this is a 60-second smoke test, no on-host watchdog needed)
#   4. (n/a - local only, no GH Actions path)
#
# Cost: under 0.05 CNY. ecs.e-c1m1.large at ~0.18 CNY/hr, held < 90 s.
#
# Run from D:\qalos:
#     .\tools\aliyun-smoke-test.ps1

[CmdletBinding()]
param(
    [string]$Region = 'cn-hangzhou',
    [string]$Zone   = 'cn-hangzhou-h',
    [string]$Prefix = 'qalos-smoke',
    [int]   $WaitSeconds = 120
)

$ErrorActionPreference = 'Stop'
$PSNativeCommandUseErrorActionPreference = $true

# --- 0. aliyun binary ---------------------------------------------------------
$aliyun = Join-Path $env:LOCALAPPDATA 'AliyunCLI\aliyun.exe'
if (-not (Test-Path $aliyun)) {
    throw "aliyun CLI not found at $aliyun. Install from https://aliyuncli.alicdn.com/aliyun-cli-windows-latest-amd64.zip"
}

# Helper: run aliyun, return parsed JSON object (or $null). Retries transient
# SDK errors. Surfaces real error lines on permanent failure.
function Invoke-AliyunJson {
    param(
        [Parameter(Mandatory)][string[]]$AliyunArgs,
        [int]$MaxAttempts = 4,
        [int]$BackoffSeconds = 3
    )
    $attempt = 0
    while ($attempt -lt $MaxAttempts) {
        $attempt++
        $text = & $aliyun @AliyunArgs 2>&1 | Out-String
        $idx = $text.IndexOf('{')
        if ($idx -ge 0) {
            try { return ($text.Substring($idx) | ConvertFrom-Json) } catch { }
        }
        $transient = ($text -match 'SDK\.ServerError') -or
                     ($text -match 'Throttling') -or
                     ($text -match 'ServiceUnavailable') -or
                     ($text -match 'InternalError')
        if ($transient -and $attempt -lt $MaxAttempts) {
            Write-Host "    (transient, retry $attempt/$MaxAttempts in $BackoffSeconds s)" -ForegroundColor DarkYellow
            Start-Sleep -Seconds $BackoffSeconds
            continue
        }
        if ($text.Trim().Length -gt 0) {
            Write-Host "    [aliyun $($AliyunArgs[0]) $($AliyunArgs[1]) failed]" -ForegroundColor Red
            ($text.Split("`n") | Where-Object { $_ -match 'ERROR|error|code' } | Select-Object -First 4) | ForEach-Object {
                Write-Host "      $_" -ForegroundColor Red
            }
        }
        return $null
    }
}

# --- 1. Auth check -----------------------------------------------------------
Write-Host "[smoke] aliyun version: $((& $aliyun version) -join ' ')" -ForegroundColor Cyan
$cfg = & $aliyun configure list 2>&1 | Out-String
if ($cfg -notmatch 'default\s*\*') { throw "no default aliyun profile. Run 'aliyun configure' first." }
Write-Host "[smoke] auth: default profile present, region $Region" -ForegroundColor Cyan

# --- 2. Pick the smallest instance type that is IN STOCK in this zone --------
# Lesson: DescribeInstanceTypes returns the catalog but doesn't tell you zone
# stock. T5 burstable instances are zone-limited and may show in the catalog
# but be SoldOut. We need DescribeAvailableResource to see what's actually
# purchasable here, then sort in PowerShell (don't pass --InstanceType as a
# filter - the API returns empty for that combination).
Write-Host "[smoke] checking stock in $Zone..." -ForegroundColor DarkGray
$stockObj = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeAvailableResource','--RegionId',$Region,'--ZoneId',$Zone,'--DestinationResource','InstanceType')
if (-not $stockObj) { throw "DescribeAvailableResource failed for $Zone" }
$inStockIds = $stockObj.AvailableZones.AvailableZone.AvailableResources.AvailableResource |
    ForEach-Object { $_.SupportedResources.SupportedResource } |
    Where-Object { $_.Status -eq 'Available' } |
    ForEach-Object { $_.Value }
Write-Host "[smoke] $Zone has $($inStockIds.Count) in-stock instance types" -ForegroundColor DarkGray

# Look up specs so we can pick the truly smallest
$specsJson = & $aliyun ecs DescribeInstanceTypes --InstanceTypes ($inStockIds | ConvertTo-Json -Compress) 2>&1 | Out-String
$sidx = $specsJson.IndexOf('{')
$allSpecs = if ($sidx -ge 0) { ($specsJson.Substring($sidx) | ConvertFrom-Json).InstanceTypes.InstanceType } else { @() }
# Pick the smallest by RAM, then by vCPU. Exclude 'poc-test' / 'ebm' / GPU families
# which are exotic (special hardware, dedicated hosts).
$chosen = $allSpecs |
    Where-Object { $_.InstanceTypeFamily -notin @('ecs.poc-test','ecs.ebm','ecs.ebmg','ecs.ebmc','ecs.ebmr','ecs.gpu','ecs.gn','ecs.sgn') -and $_.InstanceTypeId -notmatch '^ecs\.vfx' } |
    Sort-Object MemorySize, CpuCoreCount, InstanceTypeId |
    Select-Object -First 1
if (-not $chosen) { throw "no suitable in-stock instance type in $Zone after filtering exotic families" }
$chosenType = $chosen.InstanceTypeId
$chosenCpu  = $chosen.CpuCoreCount
$chosenMem  = $chosen.MemorySize
Write-Host "[smoke] chosen instance type: $chosenType ($chosenCpu vCPU, $chosenMem GB, $($chosen.InstanceTypeFamily))" -ForegroundColor Cyan

# --- 3. Resolve or create VPC -------------------------------------------------
$vpcName = "$Prefix-vpc"
$vpcList = Invoke-AliyunJson -AliyunArgs @('vpc','DescribeVpcs','--RegionId',$Region,'--VpcName',$vpcName)
if ($vpcList -and $vpcList.Vpcs.Vpc) {
    $vpcId = $vpcList.Vpcs.Vpc[0].VpcId
    Write-Host "[smoke] reusing VPC $vpcId ($vpcName)" -ForegroundColor DarkGray
} else {
    $created = Invoke-AliyunJson -AliyunArgs @('vpc','CreateVpc','--RegionId',$Region,'--CidrBlock','172.16.0.0/16','--VpcName',$vpcName,'--Description',"qalos smoke test VPC ($Prefix)")
    if (-not $created) { throw "CreateVpc failed" }
    $vpcId = $created.VpcId
    Write-Host "[smoke] created VPC $vpcId" -ForegroundColor Green
}

# --- 4. Resolve or create vSwitch --------------------------------------------
$vswName = "$Prefix-vsw"
$vswList = Invoke-AliyunJson -AliyunArgs @('vpc','DescribeVSwitches','--RegionId',$Region,'--VpcId',$vpcId,'--VSwitchName',$vswName)
if ($vswList -and $vswList.VSwitches.VSwitch) {
    $vswId = $vswList.VSwitches.VSwitch[0].VSwitchId
    $vswZone = $vswList.VSwitches.VSwitch[0].ZoneId
    Write-Host "[smoke] reusing vSwitch $vswId in $vswZone" -ForegroundColor DarkGray
} else {
    $created = Invoke-AliyunJson -AliyunArgs @('vpc','CreateVSwitch','--RegionId',$Region,'--VpcId',$vpcId,'--ZoneId',$Zone,'--CidrBlock','172.16.1.0/24','--VSwitchName',$vswName)
    if (-not $created) { throw "CreateVSwitch failed" }
    $vswId = $created.VSwitchId
    $vswZone = $Zone
    Write-Host "[smoke] created vSwitch $vswId in $vswZone" -ForegroundColor Green
}

# --- 5. Resolve or create Security Group + SSH inbound rule -----------------
$sgName = "$Prefix-sg"
$sgList = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeSecurityGroups','--RegionId',$Region,'--VpcId',$vpcId,'--SecurityGroupName',$sgName)
if ($sgList -and $sgList.SecurityGroups.SecurityGroup) {
    $sgId = $sgList.SecurityGroups.SecurityGroup[0].SecurityGroupId
    Write-Host "[smoke] reusing Security Group $sgId" -ForegroundColor DarkGray
} else {
    $created = Invoke-AliyunJson -AliyunArgs @('ecs','CreateSecurityGroup','--RegionId',$Region,'--VpcId',$vpcId,'--SecurityGroupName',$sgName,'--Description',"qalos smoke test SG ($Prefix)")
    if (-not $created) { throw "CreateSecurityGroup failed" }
    $sgId = $created.SecurityGroupId
    Write-Host "[smoke] created Security Group $sgId" -ForegroundColor Green
}
# Authorize SSH (22/22). Idempotent: AuthorizeSecurityGroup returns the
# existing rule if one is already present.
$perm = Invoke-AliyunJson -AliyunArgs @('ecs','AuthorizeSecurityGroup','--RegionId',$Region,'--SecurityGroupId',$sgId,'--IpProtocol','tcp','--PortRange','22/22','--SourceCidrIp','0.0.0.0/0','--Description','qalos smoke test SSH')
if ($perm) { Write-Host "[smoke] authorized SSH 22/22 from 0.0.0.0/0" -ForegroundColor DarkGray }

# --- 6. Resolve or import KeyPair -------------------------------------------
$kpName = "$Prefix-key"
$kpList = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeKeyPairs','--RegionId',$Region,'--KeyPairName',$kpName)
if ($kpList -and $kpList.KeyPairs.KeyPair) {
    $kpId = $kpList.KeyPairs.KeyPair[0].KeyPairId
    Write-Host "[smoke] reusing KeyPair $kpName ($kpId)" -ForegroundColor DarkGray
} else {
    $pubKeyPath = Join-Path $env:USERPROFILE '.ssh\id_rsa.pub'
    if (-not (Test-Path $pubKeyPath)) {
        Write-Host "[smoke] no ~/.ssh/id_rsa.pub found; generating ed25519 keypair for qalos-aliyun" -ForegroundColor Yellow
        $sshDir = Join-Path $env:USERPROFILE '.ssh'
        if (-not (Test-Path $sshDir)) { New-Item -ItemType Directory -Path $sshDir -Force | Out-Null }
        $pubKeyPath = Join-Path $sshDir 'id_ed25519_qalos_aliyun.pub'
        $privKeyPath = Join-Path $sshDir 'id_ed25519_qalos_aliyun'
        & ssh-keygen -t ed25519 -f $privKeyPath -N '""' -C 'qalos-aliyun' 2>&1 | Out-Null
    }
    $pubKeyText = (Get-Content $pubKeyPath -Raw).Trim()
    $imported = Invoke-AliyunJson -AliyunArgs @('ecs','ImportKeyPair','--RegionId',$Region,'--KeyPairName',$kpName,'--PublicKeyBody',$pubKeyText)
    if (-not $imported) { throw "ImportKeyPair failed" }
    Write-Host "[smoke] imported KeyPair $kpName" -ForegroundColor Green
}

# --- 7. Find the most recent stock Ubuntu 22.04 image ------------------------
$imgList = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeImages','--RegionId',$Region,'--ImageOwnerAlias','system','--OSType','linux','--Architecture','x86_64','--PageSize','100')
$ubuntuImg = $imgList.Images.Image |
    Where-Object { $_.OSName -match 'ubuntu' -and $_.OSName -match '22\.04' -and $_.OSType -eq 'linux' } |
    Sort-Object { [datetime]$_.CreationTime } -Descending |
    Select-Object -First 1
if (-not $ubuntuImg) {
    $ubuntuImg = $imgList.Images.Image |
        Where-Object { $_.OSName -match 'ubuntu_22' } |
        Sort-Object { [datetime]$_.CreationTime } -Descending |
        Select-Object -First 1
}
if (-not $ubuntuImg) { throw "No Ubuntu 22.04 image found in $Region" }
$imageId = $ubuntuImg.ImageId
Write-Host "[smoke] image: $imageId ($($ubuntuImg.OSName))" -ForegroundColor Cyan

# --- 8. RunInstances ---------------------------------------------------------
$instanceName = "$Prefix-$((Get-Date).ToString('HHmmss'))"
Write-Host "[smoke] launching $instanceName (type: $chosenType)..." -ForegroundColor Cyan
$ri = Invoke-AliyunJson -AliyunArgs @(
    'ecs','RunInstances',
    '--RegionId',$Region,
    '--ImageId',$imageId,
    '--InstanceType',$chosenType,
    '--SecurityGroupId',$sgId,
    '--VSwitchId',$vswId,
    '--InstanceName',$instanceName,
    '--InstanceChargeType','PostPaid',
    '--InternetMaxBandwidthOut','5',
    '--InternetChargeType','PayByTraffic',
    '--SystemDisk.Category','cloud_essd',
    '--SystemDisk.Size','40',
    '--KeyPairName',$kpName,
    '--Amount','1',
    '--HostName',"qalos-smoke-$((Get-Date).ToString('HHmmss'))"
)
if (-not $ri) { throw "RunInstances failed" }
$instanceId = $ri.InstanceIdSets.InstanceIdSet[0]
Write-Host "[smoke] launched $instanceId" -ForegroundColor Green

# --- 9. Background watchdog (safety net #2) ---------------------------------
# If this PowerShell process is hard-killed (kill -9, OOM, etc.), the Start-Job
# keeps running and will force-delete the instance.
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
} -ArgumentList @($aliyun, $Region, $instanceId, $PID)
Write-Host "[smoke] watchdog job $($watchdog.Id) started (parent PID $PID, watching $instanceId)" -ForegroundColor DarkGray

# --- 10. Wait for Running ----------------------------------------------------
$deadline = (Get-Date).AddSeconds($WaitSeconds)
$status = $null
$publicIp = $null
$stopWatch = [System.Diagnostics.Stopwatch]::StartNew()
try {
    while ((Get-Date) -lt $deadline) {
        $d = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeInstances','--RegionId',$Region,'--InstanceIds',"['$instanceId']")
        if ($d -and $d.Instances.Instance) {
            $status = $d.Instances.Instance[0].Status
            $publicIp = $d.Instances.Instance[0].PublicIpAddress.IpAddress
            if ($publicIp -is [array]) { $publicIp = $publicIp[0] }
            if ($status -eq 'Running') { break }
        }
        Write-Host "  [$($stopWatch.Elapsed.TotalSeconds.ToString('0'))s] status=$status ip=$publicIp" -ForegroundColor DarkGray
        Start-Sleep -Seconds 5
    }
}
finally {
    # --- 11. ALWAYS tear down (safety net #1) ---------------------------------
    # Lesson: DeleteInstance on a Running instance intermittently returns
    # SDK.ServerError. StopInstance first, then DeleteInstance is reliable.
    Write-Host "[smoke] tearing down instance $instanceId..." -ForegroundColor Cyan
    Invoke-AliyunJson -AliyunArgs @('ecs','StopInstance','--RegionId',$Region,'--InstanceId',$instanceId) | Out-Null
    # Wait for Stopped
    $stopDeadline = (Get-Date).AddSeconds(60)
    while ((Get-Date) -lt $stopDeadline) {
        $d = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeInstances','--RegionId',$Region,'--InstanceIds',"['$instanceId']")
        if ($d -and $d.Instances.Instance -and $d.Instances.Instance[0].Status -eq 'Stopped') { break }
        Start-Sleep -Seconds 3
    }
    $del = Invoke-AliyunJson -AliyunArgs @('ecs','DeleteInstance','--RegionId',$Region,'--InstanceId',$instanceId,'--Force','true')
    if (-not $del) {
        Write-Warning "DeleteInstance failed after Stop. Check the Aliyun console for $instanceId."
    } else {
        # Wait for it to actually disappear
        $delDeadline = (Get-Date).AddSeconds(60)
        while ((Get-Date) -lt $delDeadline) {
            $d = Invoke-AliyunJson -AliyunArgs @('ecs','DescribeInstances','--RegionId',$Region,'--InstanceIds',"['$instanceId']")
            $insts = $d.Instances.Instance
            if (-not $insts -or $insts.Count -eq 0) { break }
            Start-Sleep -Seconds 3
        }
    }
    # --- 12. Stop the watchdog (safety net #2 cleanup) -----------------------
    if ($watchdog) {
        Stop-Job -Job $watchdog -ErrorAction SilentlyContinue
        Remove-Job -Job $watchdog -Force -ErrorAction SilentlyContinue
    }
}

# --- 13. Persist infra state for aliyun-build.ps1 to reuse -------------------
$stateFile = Join-Path $PSScriptRoot '..\.pi\aliyun-state.json'
$stateDir = Split-Path $stateFile -Parent
if (-not (Test-Path $stateDir)) { New-Item -ItemType Directory -Path $stateDir -Force | Out-Null }
$state = [pscustomobject]@{
    region      = $Region
    zone        = $vswZone
    vpcId       = $vpcId
    vpcName     = $vpcName
    vswId       = $vswId
    vswName     = $vswName
    sgId        = $sgId
    sgName      = $sgName
    keyPairName = $kpName
    imageId     = $imageId
    updatedAt   = (Get-Date).ToString('o')
}
$state | ConvertTo-Json -Depth 3 | Set-Content -Path $stateFile -Encoding UTF8
Write-Host "[smoke] state saved to $stateFile" -ForegroundColor DarkGray

# --- 14. Report --------------------------------------------------------------
$elapsed = $stopWatch.Elapsed.TotalSeconds
if ($status -eq 'Running') {
    Write-Host ""
    Write-Host "[smoke] PASS" -ForegroundColor Green
    Write-Host "  instance   : $instanceId  (deleted)"
    Write-Host "  type       : $chosenType (~${chosenCpu} vCPU, ~${chosenMem} GB)"
    Write-Host "  image      : $imageId"
    Write-Host "  region/zone: $Region / $vswZone"
    Write-Host "  time to Running: $([math]::Round($elapsed,1))s"
    Write-Host ""
    Write-Host "Persistent resources KEPT (free) for aliyun-build.ps1:" -ForegroundColor Cyan
    Write-Host "  VPC      = $vpcId  ($vpcName)"
    Write-Host "  VSwitch  = $vswId  ($vswName)  in $vswZone"
    Write-Host "  SG       = $sgId  ($sgName)  - SSH 22/22 from 0.0.0.0/0"
    Write-Host "  KeyPair  = $kpName"
    Write-Host "  State    = $stateFile"
    Write-Host ""
    Write-Host "Cost: ~0.05 CNY for this <90 s run." -ForegroundColor DarkGray
    exit 0
} else {
    Write-Host ""
    Write-Host "[smoke] FAIL  final status was '$status' after $elapsed seconds" -ForegroundColor Red
    Write-Host "  instance $instanceId was deleted in the finally{}; check the Aliyun console for orphaned resources."
    exit 1
}
