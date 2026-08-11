[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path

Push-Location $root
try {
    & git config core.hooksPath .githooks
    if ($LASTEXITCODE -ne 0) {
        throw "Unable to configure core.hooksPath."
    }
}
finally {
    Pop-Location
}

Write-Host "Git hooks installed from .githooks."
