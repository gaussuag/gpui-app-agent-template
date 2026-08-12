[CmdletBinding(SupportsShouldProcess = $true, ConfirmImpact = "High")]
param(
    [string]$ProductSlug,
    [string]$DisplayName,
    [string]$Description,
    [string]$Publisher = "Unconfigured Publisher",
    [string]$IconPath,
    [switch]$SkipFullCheck
)

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force

Assert-CleanWorktree -Root $root
$current = Get-ProductIdentity -Root $root
$defaults = Get-TemplateIdentityDefaults
if ($current.BinaryName -ne $defaults.BinaryName) {
    throw "This repository is already initialized as '$($current.BinaryName)'. Use configure-product.ps1 for mutable identity fields."
}

if ([string]::IsNullOrWhiteSpace($ProductSlug)) {
    $ProductSlug = Get-SuggestedProductSlug -Root $root
}
Assert-ProductSlug -ProductSlug $ProductSlug
if ($ProductSlug -eq $defaults.BinaryName) {
    throw "ProductSlug still equals the template sentinel. Pass the new repository/product slug explicitly."
}
if ([string]::IsNullOrWhiteSpace($DisplayName)) {
    $DisplayName = ConvertTo-DisplayName -ProductSlug $ProductSlug
}
if ([string]::IsNullOrWhiteSpace($Description)) {
    $Description = "$DisplayName desktop application."
}
foreach ($pair in @(
    @{ Name = "DisplayName"; Value = $DisplayName },
    @{ Name = "Description"; Value = $Description },
    @{ Name = "Publisher"; Value = $Publisher }
)) {
    Assert-SingleLineValue -Name $pair.Name -Value $pair.Value
}

$year = [DateTime]::UtcNow.Year
$copyright = "Copyright (c) $year $Publisher"
$iconSummary = if ($IconPath) { (Resolve-Path -LiteralPath $IconPath).Path } else { "keep neutral template icon" }

Write-Host "Product initialization plan:"
Write-Host "  binary:     $($current.BinaryName) -> $ProductSlug"
Write-Host "  display:    $($current.ProductName) -> $DisplayName"
Write-Host "  description:$Description"
Write-Host "  publisher:  $Publisher"
Write-Host "  icon:       $iconSummary"
Write-Host "  stable crates app-core/app-ui/desktop are not renamed"

if (-not $PSCmdlet.ShouldProcess($root, "initialize product identity")) {
    return
}

Set-ProductIdentityFiles `
    -Root $root `
    -ProductSlug $ProductSlug `
    -DisplayName $DisplayName `
    -Description $Description `
    -Publisher $Publisher `
    -LegalCopyright $copyright `
    -IconPath $IconPath `
    -Profile Development

& (Join-Path $PSScriptRoot "check-product.ps1") -Profile Development
if (-not $SkipFullCheck) {
    & (Join-Path $PSScriptRoot "check.ps1")
}

Write-Host "Product initialization completed. Review and commit the generated identity changes."
