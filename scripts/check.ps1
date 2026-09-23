[CmdletBinding()]
param(
    [ValidateNotNullOrEmpty()]
    [ValidateSet("all", "docs", "static", "tests", "build", "startup", "overlay", "validators")]
    [string[]]$Group = @("all"),
    [switch]$IncludeIme
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
if ($IncludeIme -and "all" -notin $Group -and "overlay" -notin $Group) {
    throw "IncludeIme requires the all or overlay group."
}
$cargoPath = if (@($Group | Where-Object { $_ -in @("all", "static", "tests", "build", "startup", "overlay") }).Count) {
    & (Join-Path $PSScriptRoot "resolve-cargo.ps1")
}
function Test-Group([string]$Name) { "all" -in $Group -or $Name -in $Group }
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
    if (Test-Group "static") {
        & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $productProfile
        Invoke-CargoStep -Name "rustfmt" -Arguments @("fmt", "--all", "--", "--check")
        Invoke-CargoStep -Name "Clippy" -Arguments @(
            "clippy", "--workspace", "--all-targets", "--all-features", "--locked", "--", "-D", "warnings"
        )
        & (Join-Path $PSScriptRoot "check-architecture.ps1")
    }
    if (Test-Group "tests") { & (Join-Path $PSScriptRoot "test.ps1") -Suite all }
    if (Test-Group "docs") { & (Join-Path $PSScriptRoot "check-docs.ps1") }
    if (Test-Group "validators") {
        & (Join-Path $PSScriptRoot "test-docs.ps1")
        & (Join-Path $PSScriptRoot "test-check-routing.ps1")
        & (Join-Path $PSScriptRoot "test-product-identity.ps1")
        & (Join-Path $PSScriptRoot "test-ui-dependencies.ps1")
    }
    # Startup needs a current executable; shared prerequisites execute once.
    if ((Test-Group "build") -or (Test-Group "startup")) {
        Invoke-CargoStep -Name "Windows MSVC build" -Arguments @(
            "build", "--package", "desktop", "--target", "x86_64-pc-windows-msvc", "--locked"
        )
        $desktopTarget = & (Join-Path $PSScriptRoot "resolve-desktop-target.ps1")
        $artifactPath = Join-Path $desktopTarget.TargetDirectory "x86_64-pc-windows-msvc/debug/$($desktopTarget.BinaryName).exe"
        & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $productProfile -ArtifactPath $artifactPath
    }
    if (Test-Group "startup") { & (Join-Path $PSScriptRoot "smoke.ps1") -SkipBuild }
    if (Test-Group "overlay") {
        & (Join-Path $PSScriptRoot "smoke-overlay.ps1")
        if ($IncludeIme) { & (Join-Path $PSScriptRoot "smoke-overlay.ps1") -Suite ime }
    }
}
finally {
    Pop-Location
}

if ("all" -in $Group) { Write-Host "Repository quality gate passed." }
else { Write-Host "Selected check groups passed: $($Group -join ', '). Full gate not requested." }
