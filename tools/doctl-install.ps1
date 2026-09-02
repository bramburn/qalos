# qalos — install `doctl` (DigitalOcean CLI) on this Windows box.
#
# One-time setup. Run from D:\qalos:
#     .\tools\doctl-install.ps1
#
# What it does:
#   1. Tries `winget install DigitalOcean.doctl` first.
#   2. Falls back to downloading the latest windows-amd64.zip from GitHub.
#   3. Extracts to a stable path and prepends it to the user PATH.
#   4. Verifies the install.

$ErrorActionPreference = 'Stop'

if (Get-Command doctl -ErrorAction SilentlyContinue) {
    $v = (doctl version) | Select-Object -First 1
    Write-Host "doctl already installed: $v"
    exit 0
}

$installDir = Join-Path $env:LOCALAPPDATA 'Programs\doctl'
$exePath    = Join-Path $installDir 'doctl.exe'

if (Test-Path $exePath) {
    Write-Host "doctl already at $exePath"
} else {
    New-Item -ItemType Directory -Path $installDir -Force | Out-Null

    if (Get-Command winget -ErrorAction SilentlyContinue) {
        Write-Host "Installing doctl via winget..."
        winget install --id DigitalOcean.doctl --accept-source-agreements --accept-package-agreements
    }

    if (-not (Test-Path $exePath)) {
        Write-Host "winget didn't land doctl — downloading the latest release from GitHub..."
        $api  = 'https://api.github.com/repos/digitalocean/doctl/releases/latest'
        $rel  = Invoke-RestMethod -Uri $api -UseBasicParsing
        $asset = $rel.assets | Where-Object { $_.name -like 'windows-amd64.zip' } | Select-Object -First 1
        if (-not $asset) { throw "Couldn't find a windows-amd64.zip asset on the latest doctl release." }
        $zip = Join-Path $env:TEMP 'doctl.zip'
        Invoke-WebRequest -Uri $asset.browser_download_url -OutFile $zip -UseBasicParsing
        Expand-Archive -Path $zip -DestinationPath $installDir -Force
    }
}

# Ensure the install dir is on the user PATH (for future shells).
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$installDir", 'User')
    $env:Path = "$env:Path;$installDir"
    Write-Host "Added $installDir to user PATH. New shells will pick it up automatically."
}

# Authenticate — prompt the user to paste a token.
if (-not $env:DO_API_TOKEN) {
    Write-Host ""
    Write-Host "Next: get a DigitalOcean API token (read+write) at"
    Write-Host "  https://cloud.digitalocean.com/account/api/tokens/new"
    Write-Host "and either set it as the env var DO_API_TOKEN or run `doctl auth init`."
}

doctl version | Select-Object -First 3
Write-Host "doctl is ready."
