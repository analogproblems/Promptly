# Build the Windows installer from a release bundle that already has the
# C++ runtime in it (tools\windows-runtime.ps1):
#
#   tools\windows-installer.ps1 app\build\windows\x64\runner\Release 1.0.2 dist
#
# Leaves dist\promptly-1.0.2-windows-x64-setup.exe. With no version, the one
# in app\pubspec.yaml is used. Needs Inno Setup 6; GitHub's Windows runners
# usually have it, and Chocolatey installs it when they do not.
param(
    [Parameter(Mandatory = $true)]
    [string]$Bundle,
    [string]$Version = "",
    [string]$OutputDir = "dist"
)

$ErrorActionPreference = "Stop"
$root = Split-Path -Parent $PSScriptRoot

if (-not (Test-Path (Join-Path $Bundle "promptly.exe"))) {
    Write-Error "$Bundle does not hold promptly.exe; build the app first."
}
if (-not $Version) {
    $line = Select-String -Path (Join-Path $root "app\pubspec.yaml") -Pattern '^version: (\d+\.\d+\.\d+)'
    $Version = $line.Matches[0].Groups[1].Value
}

$iscc = (Get-Command iscc.exe -ErrorAction SilentlyContinue).Source
if (-not $iscc) {
    $iscc = Join-Path ${env:ProgramFiles(x86)} "Inno Setup 6\ISCC.exe"
}
if (-not (Test-Path $iscc)) {
    Write-Host "Inno Setup not found; installing it with Chocolatey."
    choco install innosetup --no-progress -y | Out-Host
    if ($LASTEXITCODE -ne 0) { Write-Error "Could not install Inno Setup." }
}

New-Item -ItemType Directory -Force $OutputDir | Out-Null
$source = (Resolve-Path $Bundle).Path
$output = (Resolve-Path $OutputDir).Path
& $iscc "/DAppVersion=$Version" "/DSourceDir=$source" "/DOutputDir=$output" (Join-Path $PSScriptRoot "windows-installer.iss")
if ($LASTEXITCODE -ne 0) { Write-Error "Inno Setup failed." }
Write-Host "Built $output\promptly-$Version-windows-x64-setup.exe"
