[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
$cargoPath = & (Join-Path $PSScriptRoot "resolve-cargo.ps1")
Import-Module (Join-Path $PSScriptRoot "lib\UiDependencies.psm1") -Force

$coreCargo = Join-Path $root "crates\app-core\Cargo.toml"
$coreSource = Join-Path $root "crates\app-core\src"
$coreText = Get-Content -Raw $coreCargo
$sourceViolations = Get-ChildItem -Path $coreSource -Recurse -Filter "*.rs" |
    Select-String -Pattern "(^\s*(use|extern\s+crate)\s+gpui(_\w+)?\b|\bgpui(_\w+)?::)"

if ($coreText -match "\bgpui([-_]\w+)*\b" -or $sourceViolations) {
    throw "Architecture violation: app-core must remain independent from GPUI."
}

$manifestPath = Join-Path $root "Cargo.toml"
$manifest = Get-Content -Raw $manifestPath
foreach ($packageName in @("gpui-kit", "toml", "winresource")) {
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
    $metadataJson = & $cargoPath metadata --locked --format-version 1 --filter-platform x86_64-pc-windows-msvc
    if ($LASTEXITCODE -ne 0) {
        throw "cargo metadata failed with exit code $LASTEXITCODE."
    }
}
finally {
    Pop-Location
}

$metadata = $metadataJson | ConvertFrom-Json
Assert-UiDependencies -Metadata $metadata
foreach ($packageName in @("winresource")) {
    $packages = @($metadata.packages | Where-Object { $_.name -eq $packageName })
    if ($packages.Count -ne 1) {
        throw "Dependency identity violation: expected one $packageName package, found $($packages.Count)."
    }
    if (-not $packages[0].source.StartsWith("registry+")) {
        throw "Dependency source violation: $packageName did not resolve from a registry."
    }
}

$workspacePackages = @{}
foreach ($packageName in @($metadata.packages | Where-Object { $_.id -in $metadata.workspace_members } | ForEach-Object name)) {
    $packages = @($metadata.packages | Where-Object { $_.name -eq $packageName -and $_.id -in $metadata.workspace_members })
    if ($packages.Count -ne 1) {
        throw "Workspace architecture violation: expected one workspace package named $packageName."
    }
    $workspacePackages[$packageName] = $packages[0]

    $memberManifest = Get-Content -Raw -LiteralPath $packages[0].manifest_path
    if ($packageName -eq 'overlay-win32') {
        if ($memberManifest -notmatch '(?ms)\[lints.rust\]\s+unsafe_code\s*=\s*"deny"\s+unused_must_use\s*=\s*"deny"') {
            throw 'Lint policy violation: overlay-win32 must deny unsafe by default and deny unused results.'
        }
        foreach ($lint in @('dbg_macro', 'expect_used', 'todo', 'unimplemented', 'unwrap_used')) {
            if ($memberManifest -notmatch "(?m)^$lint\s*=\s*`"deny`"") { throw "Lint policy violation: overlay-win32 must deny $lint." }
        }
    } elseif ($memberManifest -notmatch '(?ms)^\[lints\]\s+workspace\s*=\s*true\s*$') {
        throw "Lint policy violation: $packageName must inherit workspace lints."
    }
}
foreach ($sourceFile in Get-ChildItem -LiteralPath (Join-Path $root 'crates') -Recurse -Filter '*.rs') {
    $relativePath = [IO.Path]::GetRelativePath($root, $sourceFile.FullName)
    Assert-OverlaySource -RelativePath $relativePath -Source (Get-Content -Raw -LiteralPath $sourceFile.FullName)
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

Assert-Dependencies -PackageName "app-core" -Forbidden @("app-ui", "desktop")
Assert-Dependencies -PackageName "app-ui" -Required @("app-core", "gpui-kit") -Forbidden @("desktop")
Assert-Dependencies -PackageName "desktop" -Required @("app-ui") -Forbidden @("app-core")

$desktopBuildDependencies = @($workspacePackages["desktop"].dependencies | Where-Object {
    $_.kind -eq "build"
})
foreach ($dependency in @("toml", "winresource")) {
    if ($desktopBuildDependencies.name -notcontains $dependency) {
        throw "Product resource architecture violation: desktop needs build dependency $dependency."
    }
}
$desktopBinaries = @($workspacePackages["desktop"].targets | Where-Object { $_.kind -contains "bin" })
if ($desktopBinaries.Count -ne 1) {
    throw "Product identity architecture violation: desktop must expose exactly one binary target."
}

$desktopBuildScript = Get-Content -Raw (Join-Path $root "crates\desktop\build.rs")
if ($desktopBuildScript -match '\bset_manifest(_file)?\s*\(') {
    throw "Windows manifest ownership violation: GPUI is the sole application-manifest owner."
}

Write-Host "Architecture and UI dependency identity checks passed."
