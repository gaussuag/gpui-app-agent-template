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

$manifestXml = @'
<assembly xmlns="urn:schemas-microsoft-com:asm.v1" manifestVersion="1.0">
  <application xmlns="urn:schemas-microsoft-com:asm.v3">
    <windowsSettings>
      <dpiAware xmlns="http://schemas.microsoft.com/SMI/2005/WindowsSettings">true/pm</dpiAware>
      <dpiAwareness xmlns="http://schemas.microsoft.com/SMI/2016/WindowsSettings">PerMonitorV2</dpiAwareness>
    </windowsSettings>
  </application>
  <dependency><dependentAssembly>
    <assemblyIdentity name="Microsoft.Windows.Common-Controls" version="6.0.0.0" />
  </dependentAssembly></dependency>
</assembly>
'@
Assert-WindowsManifest -Manifest ([xml]$manifestXml)
Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('true/pm', 'true'))
Assert-Rejected -Case "DPI unaware manifest" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('true/pm', 'false'))
}
Assert-Rejected -Case "missing DPI declaration" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('dpiAware ', 'missing ').Replace('</dpiAware>', '</missing>'))
}
Assert-Rejected -Case "missing PerMonitorV2" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('PerMonitorV2', 'System'))
}
Assert-Rejected -Case "old Common Controls" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('6.0.0.0', '5.0.0.0'))
}
Assert-Rejected -Case "missing Common Controls" -Action {
    Assert-WindowsManifest -Manifest ([xml]$manifestXml.Replace('Microsoft.Windows.Common-Controls', 'Other.Controls'))
}

$checkText = [IO.File]::ReadAllText((Join-Path $PSScriptRoot "check.ps1"))
$profileMatch = [regex]::Match($checkText, '(?m)^\$productProfile\s*=\s*"(?<profile>Template|Development|Release)"\s*$')
if (-not $profileMatch.Success) {
    throw "Could not resolve the canonical product profile from scripts/check.ps1."
}
$profile = $profileMatch.Groups["profile"].Value
$repositoryPolicy = Get-Content -LiteralPath (Join-Path $root ".agentinfra\policy.json") -Raw -Encoding utf8 |
    ConvertFrom-Json -Depth 100
$expectedRepositoryProfile = if ($profile -eq "Template") { "template" } else { "product" }
if ($repositoryPolicy.repository_profile -ne $expectedRepositoryProfile) {
    throw "Product profile '$profile' requires repository_profile '$expectedRepositoryProfile'."
}
& (Join-Path $PSScriptRoot "check-product.ps1") -Profile $profile | Out-Null
$wrongProfile = if ($profile -eq "Template") { "Release" } else { "Template" }
Assert-Rejected -Case "$wrongProfile policy against a $profile repository" -Action {
    & (Join-Path $PSScriptRoot "check-product.ps1") -Profile $wrongProfile
}

Write-Host "Product identity positive and negative policy self-tests passed."
