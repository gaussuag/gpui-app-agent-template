[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
Import-Module (Join-Path $PSScriptRoot "lib\UiDependencies.psm1") -Force

# Cargo-shaped data tests the resolved graph without a registry or a checkout edit.
function New-MetadataFixture {
    $packages = @(
        foreach ($name in @("gpui-kit", "gpui-base", "gpui-component", "gpui-component-macros", "gpui-kit-assets")) {
            @{ name = $name; id = $name; version = "0.6.4"; source = "registry+https://github.com/rust-lang/crates.io-index" }
        }
        foreach ($name in @("gpui-pre", "gpui-pre-platform", "gpui-pre-windows", "gpui-pre-macros")) {
            @{ name = $name; id = $name; version = "0.3.6"; source = "registry+https://github.com/rust-lang/crates.io-index" }
        }
        # This is a republished third-party crate, not a Zed snapshot version.
        @{ name = "gpui-pre-reqwest"; id = "gpui-pre-reqwest"; version = "0.12.15"; source = "registry+https://github.com/rust-lang/crates.io-index" }
        @{ name = "app-core"; id = "core"; dependencies = @(); features = @{} }
        @{
            name = "app-ui"; id = "ui"
            dependencies = @(
                @{ name = "app-core"; kind = $null; features = @() }
                @{ name = "gpui-kit"; kind = $null; features = @("component", "assets") }
                @{ name = "gpui-kit"; kind = "dev"; features = @("test-support") }
            )
            features = @{ "test-support" = @("gpui-kit/test-support") }
        }
        @{ name = "desktop"; id = "desktop"; dependencies = @(@{ name = "app-ui"; kind = $null; features = @() }); features = @{} }
    )
    return @{ metadata = @{ "ui-bom" = @{ "gpui-pre" = "0.3.6" } }; packages = $packages; workspace_members = @("core", "ui", "desktop"); resolve = @{ nodes = @(
        @{ id = "gpui-pre"; features = @("windows-manifest") }
    ) } } | ConvertTo-Json -Depth 20 | ConvertFrom-Json
}

function Assert-Rejected {
    param([string]$Case, [scriptblock]$Mutate, [string]$Message)
    $fixture = New-MetadataFixture
    & $Mutate $fixture
    try { Assert-UiDependencies -Metadata $fixture }
    catch {
        if ($_.Exception.Message -notlike "*$Message*") {
            throw "Unexpected rejection for ${Case}: $($_.Exception.Message)"
        }
        return
    }
    throw "UI dependency self-test failed: expected rejection for $Case."
}

Assert-UiDependencies -Metadata (New-MetadataFixture)
Assert-Rejected "duplicate GPUI identity" {
    param($m)
    $m.packages += [pscustomobject]@{ name = "gpui-pre"; id = "duplicate"; version = "0.3.5"; source = "registry+other" }
} "expected one gpui-pre"
Assert-Rejected "legacy GPUI alongside Kit" {
    param($m)
    $m.packages += [pscustomobject]@{ name = "gpui"; id = "legacy"; version = "0.2.2"; source = "registry+other" }
} "legacy GPUI"
Assert-Rejected "git snapshot" {
    param($m)
    ($m.packages | Where-Object name -eq "gpui-pre-platform").source = "git+https://example.invalid/gpui"
} "registry"
Assert-Rejected "missing component" {
    param($m)
    $m.packages = @($m.packages | Where-Object name -ne "gpui-component")
} "expected one gpui-component"
Assert-Rejected "mixed snapshot versions" {
    param($m)
    ($m.packages | Where-Object name -eq "gpui-pre-macros").version = "0.3.5"
} "snapshot versions"
Assert-Rejected "mixed Kit layer versions" {
    param($m)
    ($m.packages | Where-Object name -eq "gpui-component").version = "0.6.2"
} "Kit layer versions"
Assert-Rejected "missing Windows manifest" {
    param($m)
    $m.resolve.nodes[0].features = @()
} "windows-manifest"
Assert-Rejected "unreviewed compatible update" {
    param($m)
    $m.metadata."ui-bom"."gpui-pre" = "0.3.5"
} "reviewed snapshot"
Assert-Rejected "core UI dependency under an alias" {
    param($m)
    ($m.packages | Where-Object name -eq "app-core").dependencies = @([pscustomobject]@{ name = "gpui-kit"; rename = "ui" })
} "app-core"
Assert-Rejected "desktop platform dependency" {
    param($m)
    ($m.packages | Where-Object name -eq "desktop").dependencies += [pscustomobject]@{ name = "gpui-pre-platform" }
} "desktop"
Assert-Rejected "app-ui bypasses facade" {
    param($m)
    ($m.packages | Where-Object name -eq "app-ui").dependencies += [pscustomobject]@{ name = "gpui-component" }
} "facade"
Assert-Rejected "missing runtime facade" {
    param($m)
    $ui = $m.packages | Where-Object name -eq "app-ui"
    $ui.dependencies = @($ui.dependencies | Where-Object { $_.name -ne "gpui-kit" -or $_.kind -eq "dev" })
} "runtime"
Assert-Rejected "missing test feature forwarding" {
    param($m)
    ($m.packages | Where-Object name -eq "app-ui").features."test-support" = @()
} "test-support"
Assert-Rejected "missing test dependency feature" {
    param($m)
    $ui = $m.packages | Where-Object name -eq "app-ui"
    ($ui.dependencies | Where-Object kind -eq "dev").features = @()
} "test-support"

Write-Host "GPUI Kit dependency policy self-tests passed."
