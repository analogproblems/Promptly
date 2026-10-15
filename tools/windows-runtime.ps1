# Copy the Microsoft C++ runtime into a Windows bundle, so the app runs on
# a PC that never had it installed.
#
# The Flutter runner, its plugins and the Rust engine all link to the
# Visual C++ runtime (vcruntime140.dll, msvcp140.dll and their companions),
# which Windows does not ship. Apps with an installer run Microsoft's
# vc_redist.x64.exe first; a zip has no installer, so the files go next to
# promptly.exe instead. Microsoft calls this "local deployment" and allows
# it for the files in Visual Studio's Redist folder, which is where this
# script takes them from.
#
#   tools\windows-runtime.ps1 app\build\windows\x64\runner\Release
#
# Visual Studio (or the Build Tools) must be installed; the files come from
# <Visual Studio>\VC\Redist\MSVC\<version>\x64\Microsoft.VC14x.CRT.
param(
    [Parameter(Mandatory = $true)]
    [string]$Bundle
)

$ErrorActionPreference = "Stop"

if (-not (Test-Path (Join-Path $Bundle "promptly.exe"))) {
    Write-Error "$Bundle does not hold promptly.exe; build the app first."
}

# Where Visual Studio is. vswhere ships with every Visual Studio and Build
# Tools install, at a fixed location.
$vswhere = Join-Path ${env:ProgramFiles(x86)} "Microsoft Visual Studio\Installer\vswhere.exe"
if (-not (Test-Path $vswhere)) {
    Write-Error "vswhere.exe not found at $vswhere; is Visual Studio installed?"
}
$installs = & $vswhere -products * -requires Microsoft.VisualStudio.Component.VC.Tools.x86.x64 -property installationPath
if (-not $installs) {
    Write-Error "No Visual Studio install with the C++ tools was found."
}

# The newest CRT folder across every install: VC\Redist\MSVC\<version>\x64\Microsoft.VC14x.CRT.
$crt = @()
foreach ($install in $installs) {
    $redist = Join-Path $install "VC\Redist\MSVC"
    if (Test-Path $redist) {
        $crt += Get-ChildItem -Path $redist -Directory -Recurse -Filter "Microsoft.VC*.CRT" |
            Where-Object { $_.FullName -match '\\\d+\.\d+\.\d+\\x64\\Microsoft\.VC\d+\.CRT$' }
    }
}
if (-not $crt) {
    Write-Error "No x64 Microsoft.VC14x.CRT folder under any Visual Studio install."
}
$from = $crt | Sort-Object { [version]($_.FullName -replace '.*\\(\d+\.\d+\.\d+)\\x64\\.*', '$1') } | Select-Object -Last 1

Write-Host "Copying the C++ runtime from $($from.FullName)"
$copied = @()
foreach ($dll in Get-ChildItem -Path $from.FullName -Filter "*.dll") {
    Copy-Item -Path $dll.FullName -Destination $Bundle -Force
    $copied += $dll.Name
}
if (-not $copied) {
    Write-Error "The runtime folder held no DLLs."
}
Write-Host ("Added to {0}: {1}" -f $Bundle, ($copied -join ", "))
