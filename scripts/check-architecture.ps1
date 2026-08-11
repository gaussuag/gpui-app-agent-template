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

Write-Host "Architecture and UI dependency identity checks passed."
