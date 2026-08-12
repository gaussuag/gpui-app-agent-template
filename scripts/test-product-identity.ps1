[CmdletBinding()]
param()

$ErrorActionPreference = "Stop"
$root = (Resolve-Path (Join-Path $PSScriptRoot "..")).Path
Import-Module (Join-Path $PSScriptRoot "product-identity.psm1") -Force

function Assert-Rejected {
    param([Parameter(Mandatory = $true)][scriptblock]$Action, [Parameter(Mandatory = $true)][string]$Case)
    try {
        & $Action | Out-Null
    }
    catch {
        return
    }
    throw "Product identity self-test expected rejection for $Case."
}

$slug = ConvertTo-ProductSlug -Value "Invoice Studio Desktop"
if ($slug -ne "invoice-studio-desktop") {
    throw "Product slug normalization returned '$slug'."
}
if ((ConvertTo-DisplayName -ProductSlug $slug) -ne "Invoice Studio Desktop") {
    throw "Display-name suggestion did not preserve slug words."
}
Assert-Rejected -Case "uppercase product slug" -Action {
    Assert-ProductSlug -ProductSlug "Invoice-Studio"
}
Assert-Rejected -Case "unsafe product slug punctuation" -Action {
    Assert-ProductSlug -ProductSlug "invoice/studio"
}
Assert-Rejected -Case "multiline identity field" -Action {
    Assert-SingleLineValue -Name "ProductName" -Value "Invoice`nStudio"
}

$checkText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "check.ps1"))
$profileMatch = [regex]::Match($checkText, '(?m)^\$productProfile\s*=\s*"(?<profile>Template|Development|Release)"\s*$')
if (-not $profileMatch.Success) {
    throw "Could not resolve the canonical product profile from scripts/check.ps1."
}
$profile = $profileMatch.Groups["profile"].Value
& (Join-Path $PSScriptRoot "check-product.ps1") -Profile $profile | Out-Null
$wrongProfile = if ($profile -eq "Template") { "Release" } else { "Template" }
Assert-Rejected -Case "$wrongProfile policy against a $profile repository" -Action {
    & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $wrongProfile
}

Write-Host "Product identity positive and negative policy self-tests passed."
