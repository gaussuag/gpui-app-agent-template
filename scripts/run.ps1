[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")
$desktopTarget = & (Join-Path $PSScriptRoot "resolve-desktop-target.ps1")

Push-Location $root
try {
    & $cargoPath run --package $desktopTarget.PackageName --bin $desktopTarget.BinaryName --locked
    if ($LASTEXITCODE -ne 0) {
        throw "Desktop application exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
