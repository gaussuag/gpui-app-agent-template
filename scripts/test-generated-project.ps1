[CmdletBinding()]
param([switch]$IncludeIme)

$ErrorActionPreference = "Stop"
$sourceRoot = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force
$sourceIdentity = Get-ProductIdentity -Root $sourceRoot
$templateIdentity = Get-TemplateIdentityDefaults
if ($sourceIdentity.BinaryName -ne $templateIdentity.BinaryName) {
    Write-Host "SKIPPED: generated-product fixture is template-only for product repositories."
    return
}
$tempBase = [IO.Path]::GetFullPath([IO.Path]::GetTempPath()).TrimEnd('\') + '\'
$fixtureRoot = Join-Path $tempBase ("gpui fixture " + [Guid]::NewGuid().ToString("N").Substring(0, 8))
$fixtureRoot = [IO.Path]::GetFullPath($fixtureRoot)
$previousTargetDirectory = $env:CARGO_TARGET_DIR
$env:CARGO_TARGET_DIR = Join-Path $sourceRoot "target"
if (-not $fixtureRoot.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
    throw "Generated-project fixture escaped the system temporary directory: $fixtureRoot"
}

try {
    New-Item -ItemType Directory -Path $fixtureRoot | Out-Null
    Write-Host "==> copy template to spaced-path fixture"
    & robocopy $sourceRoot $fixtureRoot /E /XD .git target /NFL /NDL /NJH /NJS /NP | Out-Null
    if ($LASTEXITCODE -gt 7) {
        throw "robocopy failed with exit code $LASTEXITCODE."
    }

    Push-Location $fixtureRoot
    try {
        & git init --quiet
        if ($LASTEXITCODE -ne 0) { throw "fixture git init failed." }
        & git config user.name "GPUI Template Fixture"
        if ($LASTEXITCODE -ne 0) { throw "fixture git user.name failed." }
        & git config user.email "fixture@example.invalid"
        if ($LASTEXITCODE -ne 0) { throw "fixture git user.email failed." }
        & git add --all
        if ($LASTEXITCODE -ne 0) { throw "fixture git add failed." }
        & git commit --quiet -m "chore: seed generated project fixture"
        if ($LASTEXITCODE -ne 0) { throw "fixture seed commit failed." }

        Write-Host "==> initialize generated product"
        $unicodeDisplay = "Lumen $([char]0x7B14)$([char]0x8BB0) Studio"
        & .\scripts\init-project.ps1 `
            -ProductSlug "lumen-notes" `
            -DisplayName $unicodeDisplay `
            -Description "A Unicode-aware fixture for the generated GPUI desktop project." `
            -Publisher "Example Fixture Labs" `
            -IconPath .\scripts\fixtures\product-icon.ico `
            -SkipFullCheck `
            -Confirm:$false

        Import-Module .\scripts\product-identity.psm1 -Force
        $initializedIdentity = Get-ProductIdentity -Root $fixtureRoot
        if ($initializedIdentity.ProductName -cne $unicodeDisplay) {
            throw "Initializer did not preserve the exact Unicode ProductName."
        }
        if ($initializedIdentity.BinaryName -cne "lumen-notes") {
            throw "Initializer did not set the generated product binary identity."
        }

        Write-Host "==> prove generated-product fixture skips product repositories"
        & .\scripts\test-generated-project.ps1

        foreach ($rolePath in @("crates\app-core", "crates\app-ui", "crates\desktop")) {
            if (-not (Test-Path -LiteralPath $rolePath -PathType Container)) {
                throw "Initializer renamed stable architecture role: $rolePath"
            }
        }
        $sensitivePaths = @(
            "crates\desktop\Cargo.toml",
            "crates\app-ui\src\lib.rs",
            "README.md",
            "LICENSE",
            "scripts\run.ps1",
            "scripts\smoke.ps1"
        )
        $residuals = @(Select-String -Path $sensitivePaths -SimpleMatch -Pattern "gpui-app-agent-template", "GPUI Agent Template")
        if ($residuals.Count -gt 0) {
            throw "Generated project retained product identity sentinels:`n$($residuals -join "`n")"
        }

        Write-Host "==> run generated repository canonical gate"
        & .\scripts\check.ps1 -IncludeIme:$IncludeIme

        & git add --all
        if ($LASTEXITCODE -ne 0) { throw "fixture initialized git add failed." }
        & git commit --quiet -m "chore: record initialized product"
        if ($LASTEXITCODE -ne 0) { throw "fixture initialized commit failed." }

        Write-Host "==> reconfigure mutable product identity"
        $configuredDisplay = "$unicodeDisplay Suite"
        & .\scripts\configure-product.ps1 `
            -DisplayName $configuredDisplay `
            -Description "A reconfigured identity fixture for release resources." `
            -Profile Release `
            -SkipFullCheck `
            -Confirm:$false
        $configuredIdentity = Get-ProductIdentity -Root $fixtureRoot
        if ($configuredIdentity.ProductName -cne $configuredDisplay -or $configuredIdentity.BinaryName -cne "lumen-notes") {
            throw "Mutable configuration changed the binary name or lost the exact ProductName."
        }

        Write-Host "==> build and inspect generated release artifact"
        $cargoPath = & .\scripts\resolve-cargo.ps1
        & $cargoPath build --package desktop --target x86_64-pc-windows-msvc --release --locked
        if ($LASTEXITCODE -ne 0) {
            throw "Generated release build failed with exit code $LASTEXITCODE."
        }
        $desktopTarget = & .\scripts\resolve-desktop-target.ps1
        $releaseArtifact = Join-Path $desktopTarget.TargetDirectory "x86_64-pc-windows-msvc\release\lumen-notes.exe"
        & .\scripts\check-product.ps1 -Profile Release -ArtifactPath $releaseArtifact
    }
    finally {
        Pop-Location
    }
}
finally {
    if ($null -eq $previousTargetDirectory) {
        Remove-Item Env:CARGO_TARGET_DIR -ErrorAction SilentlyContinue
    }
    else {
        $env:CARGO_TARGET_DIR = $previousTargetDirectory
    }
    if (Test-Path -LiteralPath $fixtureRoot) {
        $resolvedFixture = [IO.Path]::GetFullPath((Resolve-Path -LiteralPath $fixtureRoot).Path)
        if (-not $resolvedFixture.StartsWith($tempBase, [StringComparison]::OrdinalIgnoreCase)) {
            throw "Refusing to remove fixture outside the system temporary directory: $resolvedFixture"
        }
        # Preserve controlled native evidence before deleting the temporary
        # project, especially when a gate failed. Each run gets its own folder.
        $evidenceDirectory = Join-Path $sourceRoot ("target/generated-overlay/" + (Split-Path $resolvedFixture -Leaf))
        $evidenceNames = @("probe-hud.bmp", "probe-interactive.bmp", "probe-input.bmp", "probe-switched.bmp", "probe-ime-composition.bmp", "probe-ime-preview-composition.bmp", "probe-ime-preview-input.bmp", "overlay-geometry.json", "overlay-fallback.json")
        foreach ($containerName in @("preview", "overlay")) {
            foreach ($componentName in @("dialog", "sheet", "menu", "notification", "tooltip", "scroll")) {
                $evidenceNames += "probe-components-$containerName-$componentName.bmp"
            }
        }
        foreach ($evidenceName in $evidenceNames) {
            $evidencePath = Join-Path $resolvedFixture "target/$evidenceName"
            if (Test-Path -LiteralPath $evidencePath -PathType Leaf) {
                New-Item -ItemType Directory -Path $evidenceDirectory -Force | Out-Null
                Copy-Item -LiteralPath $evidencePath -Destination (Join-Path $evidenceDirectory $evidenceName)
            }
        }
        Remove-Item -LiteralPath $resolvedFixture -Recurse -Force
    }
}

Write-Host "Generated repository passed initialization, canonical, residual, and release-resource checks."
