# qalos - install the Aliyun CLI on this Windows box.
#
# One-time setup. Run from D:\qalos:
#     .\tools\aliyun-install.ps1
#
# Mirrors tools\doctl-install.ps1. Idempotent: detects an existing install.
# Drops the binary in %LOCALAPPDATA%\AliyunCLI\ (matches the official
# PowerShell installer script from the Aliyun docs, so the install path is
# stable across machines).
#
# Auth: after this script finishes, run `aliyun configure` once to provide
# an AccessKey ID + Secret + default region. The default profile is what
# the other tools/* scripts read.

$ErrorActionPreference = 'Stop'

$installDir = Join-Path $env:LOCALAPPDATA 'AliyunCLI'
$exePath    = Join-Path $installDir 'aliyun.exe'

# Already installed? Print version and exit.
if (Test-Path $exePath) {
    $v = (& $exePath version) | Select-Object -First 1
    Write-Host "aliyun already installed: $v at $exePath"
    exit 0
}

New-Item -ItemType Directory -Path $installDir -Force | Out-Null

# Download the latest Windows amd64 build from Aliyun's CDN.
$url  = 'https://aliyuncli.alicdn.com/aliyun-cli-windows-latest-amd64.zip'
$zip  = Join-Path $env:TEMP 'aliyun-cli.zip'
Write-Host "Downloading $url ..."
Invoke-WebRequest -Uri $url -OutFile $zip -UseBasicParsing
Expand-Archive -Path $zip -DestinationPath $installDir -Force

# Add the install dir to the user PATH if it isn't already.
$userPath = [Environment]::GetEnvironmentVariable('Path', 'User')
if ($userPath -notlike "*$installDir*") {
    [Environment]::SetEnvironmentVariable('Path', "$userPath;$installDir", 'User')
    $env:Path = "$env:Path;$installDir"
    Write-Host "Added $installDir to user PATH. New shells will pick it up automatically."
}

Write-Host ""
& $exePath version | Select-Object -First 2
Write-Host ""
Write-Host "aliyun is ready."
Write-Host ""
Write-Host "Next: configure credentials with 'aliyun configure' (one-time, interactive)."
Write-Host "You'll need an Alibaba Cloud AccessKey ID and Secret. Recommended: create a"
Write-Host "dedicated RAM user with AliyunECSFullAccess + AliyunVPCFullAccess, NOT the root"
Write-Host "account key. See https://ram.console.aliyun.com/users for RAM user setup."
Write-Host ""
Write-Host "After configuring, run tools\aliyun-smoke-test.ps1 to prove end-to-end works."
