[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")

$coreCargo = Join-Path $root "crates\app-core\Cargo.toml"
$coreSource = Join-Path $root "crates\app-core\src"
$coreText = Get-Content -Raw $coreCargo
$sourceViolations = Get-ChildItem -Path $coreSource -Recurse -Filter "*.rs" |
    Select-String -Pattern "(^\s*(use|extern\s+crate)\s+gpui(_component)?\b|\bgpui(_component)?::)"

if ($coreText -match "\bgpui(-component)?\b" -or $sourceViolations) {
    throw "Architecture violation: app-core must remain independent from GPUI."
}

$manifestPath = Join-Path $root "Cargo.toml"
$manifest = Get-Content -Raw $manifestPath
foreach ($packageName in @("gpui", "gpui-component")) {
    $dependencyLine = ($manifest -split "`n" |
        Where-Object { $_ -match "^$([regex]::Escape($packageName))\s*=" } |
        Select-Object -First 1)
    if (-not $dependencyLine -or $dependencyLine -notmatch 'version\s*=\s*"=') {
        throw "Dependency policy violation: $packageName must use an exact registry version."
    }
    if ($dependencyLine -match "\b(git|branch|rev|path)\s*=") {
        throw "Dependency policy violation: $packageName must use the registry baseline."
    }
}

if ($manifest -match "(?m)^\[patch\.") {
    throw "Dependency policy violation: baseline workspaces cannot contain [patch] entries."
}

Push-Location $root
try {
    $metadataJson = & $cargoPath metadata --locked --format-version 1
    if ($LASTEXITCODE -ne 0) {
        throw "cargo metadata failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$metadata = $metadataJson | ConvertFrom-Json
foreach ($packageName in @("gpui", "gpui-component")) {
    $packages = @($metadata.packages | Where-Object { $_.name -eq $packageName })
    if ($packages.Count -ne 1) {
        throw "Dependency identity violation: expected one $packageName package, found $($packages.Count)."
    }
    if (-not $packages[0].source.StartsWith("registry+")) {
        throw "Dependency source violation: $packageName did not resolve from a registry."
    }
}

$workspacePackages = @{}
foreach ($packageName in @("app-core", "app-ui", "desktop")) {
    $packages = @($metadata.packages | Where-Object { $_.name -eq $packageName -and $_.id -in $metadata.workspace_members })
    if ($packages.Count -ne 1) {
        throw "Workspace architecture violation: expected one workspace package named $packageName."
    }
    $workspacePackages[$packageName] = $packages[0]

    $memberManifest = Get-Content -Raw -LiteralPath $packages[0].manifest_path
    if ($memberManifest -notmatch '(?ms)^\[lints\]\s+workspace\s*=\s*true\s*$') {
        throw "Lint policy violation: $packageName must inherit workspace lints."
    }
}

function Assert-Dependencies {
    param(
        [Parameter(Mandatory = $true)]
        [string]$PackageName,
        [string[]]$Required = @(),
        [string[]]$Forbidden = @()
    )

    $dependencyNames = @($workspacePackages[$PackageName].dependencies.name)
    foreach ($dependency in $Required) {
        if ($dependencyNames -notcontains $dependency) {
            throw "Workspace architecture violation: $PackageName must depend on $dependency."
        }
    }
    foreach ($dependency in $Forbidden) {
        if ($dependencyNames -contains $dependency) {
            throw "Workspace architecture violation: $PackageName must not depend on $dependency."
        }
    }
}

Assert-Dependencies -PackageName "app-core" -Forbidden @("app-ui", "desktop", "gpui", "gpui-component")
Assert-Dependencies -PackageName "app-ui" -Required @("app-core", "gpui", "gpui-component") -Forbidden @("desktop")
Assert-Dependencies -PackageName "desktop" -Required @("app-ui") -Forbidden @("app-core", "gpui", "gpui-component")

$testSupportFeature = @($workspacePackages["app-ui"].features."test-support")
if ($testSupportFeature -notcontains "gpui/test-support") {
    throw "Test architecture violation: app-ui test-support must enable gpui/test-support."
}
$gpuiTestDependencies = @($workspacePackages["app-ui"].dependencies | Where-Object {
    $_.name -eq "gpui" -and $_.kind -eq "dev"
})
if (
    $gpuiTestDependencies.Count -ne 1 -or
    $gpuiTestDependencies[0].features -notcontains "test-support"
) {
    throw "Test architecture violation: app-ui needs one GPUI dev dependency with test-support."
}

Write-Host "Architecture and UI dependency identity checks passed."
