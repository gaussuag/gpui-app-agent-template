[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")
$productProfile = "Template"

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
    Write-Host "==> source product identity ($productProfile)"
    & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $productProfile
    Invoke-CargoStep -Name "rustfmt" -Arguments @("fmt", "--all", "--", "--check")
    Invoke-CargoStep -Name "Clippy" -Arguments @(
        "clippy", "--workspace", "--all-targets", "--all-features", "--locked", "--", "-D", "warnings"
    )
    & (Join-Path $PSScriptRoot "test.ps1") -Suite all
    Write-Host "==> Agent repository contracts"
    & (Join-Path $PSScriptRoot "check-agent-contract.ps1")
    Write-Host "==> source risk policy"
    & (Join-Path $PSScriptRoot "check-source-risks.ps1")
    Write-Host "==> policy script self-tests"
    & (Join-Path $PSScriptRoot "test-policy-scripts.ps1")
    Write-Host "==> architecture and dependency identity"
    & (Join-Path $PSScriptRoot "check-architecture.ps1")
    Invoke-CargoStep -Name "Windows MSVC build" -Arguments @(
        "build", "--package", "desktop", "--target", "x86_64-pc-windows-msvc", "--locked"
    )
    $desktopTarget = & (Join-Path $PSScriptRoot "resolve-desktop-target.ps1")
    $artifactPath = Join-Path $desktopTarget.TargetDirectory "x86_64-pc-windows-msvc\debug\$($desktopTarget.BinaryName).exe"
    Write-Host "==> built Windows product identity ($productProfile)"
    & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $productProfile -ArtifactPath $artifactPath
    & (Join-Path $PSScriptRoot "smoke.ps1") -SkipBuild
}
finally {
    Pop-Location
}

Write-Host "Repository quality gate passed."
Write-Host "For Agent change tasks, continue docs/agent-workflow.md until Git delivery, commit-range, worktree-status, and handoff are complete."
