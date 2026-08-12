[CmdletBinding()]
param(
    [ValidateSet("all", "core", "gpui", "workspace")]
    [string]$Suite = "all"
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")

function Invoke-TestSuite {
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
    if ($Suite -in @("all", "core")) {
        Invoke-TestSuite -Name "pure core tests" -Arguments @(
            "test", "--package", "app-core", "--locked"
        )
    }
    if ($Suite -in @("all", "gpui")) {
        Invoke-TestSuite -Name "GPUI headless tests" -Arguments @(
            "test", "--package", "app-ui", "--features", "test-support", "--locked"
        )
    }
    if ($Suite -in @("all", "workspace")) {
        Invoke-TestSuite -Name "workspace tests" -Arguments @(
            "test", "--workspace", "--all-features", "--locked"
        )
    }
}
finally {
    Pop-Location
}

Write-Host "Requested test suite passed: $Suite"
