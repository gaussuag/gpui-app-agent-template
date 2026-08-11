[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")

Push-Location $root
try {
    & $cargoPath run --package desktop --bin gpui-app-agent-template --locked
    if ($LASTEXITCODE -ne 0) {
        throw "Desktop application exited with code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}
