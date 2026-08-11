[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")

function Invoke-CargoStep {
    param(
        [Parameter(Mandatory = $true)]
        [string]$Name,
        [Parameter(Mandatory = $true)]
        [string[]]$Arguments
    )

    Write-Host "==> $Name"
    & $cargoPath @Arguments
    if ($LASTEXITCODE -ne 0) {
        throw "$Name failed with exit code $LASTEXITCODE."
    }
}

Push-Location $root
try {
    Invoke-CargoStep -Name "rustfmt" -Arguments @("fmt", "--all", "--", "--check")
    Invoke-CargoStep -Name "Clippy" -Arguments @(
        "clippy", "--workspace", "--all-targets", "--all-features", "--locked", "--", "-D", "warnings"
    )
    Invoke-CargoStep -Name "tests" -Arguments @(
        "test", "--workspace", "--all-features", "--locked"
    )
    & (Join-Path $PSScriptRoot "check-architecture.ps1")
    Invoke-CargoStep -Name "Windows MSVC build" -Arguments @(
        "build", "--package", "desktop", "--target", "x86_64-pc-windows-msvc", "--locked"
    )
}
finally {
    Pop-Location
}

Write-Host "All checks passed."
